#!/bin/sh
# 복원 시험 (GPU-128): 맥에서 관리자 SSO로 최신 백업을 받아 임시 PostgreSQL 16에 복원 → 백업 때 센 행 수와 비교
#
#   aws sso login --profile devoops
#   sh db/backup/restore_test.sh                       # 가장 최근 백업
#   sh db/backup/restore_test.sh gpuf_data-20261116T…Z.dump   # 특정 백업
#
# DB VM 역할은 쓰기만 있어서(ADR-14 · ADR-31) 받기는 관리자 권한으로 한다. 임시 DB는 끝나면 지운다.
set -eu
PROFILE=${AWS_PROFILE:-devoops}
BUCKET=${BACKUP_BUCKET:-devoops-prod-ckpt-$(aws --profile "$PROFILE" sts get-caller-identity --query Account --output text)-us-east-2}  # 계정은 SSO 프로필에서
PREFIX=${BACKUP_PREFIX:-backups/db}
PG_BIN=${PG_BIN:-/opt/homebrew/opt/postgresql@16/bin}
PORT=${PORT:-55432}

name=${1:-}
if [ -z "$name" ]; then  # 행 수 파일이 있는(= 업로드가 끝난) 가장 최근 덤프
  name=$(aws --profile "$PROFILE" s3 ls "s3://$BUCKET/$PREFIX/" | awk '{print $4}' | sed -n 's/\.counts\.json$//p' | sort | tail -1)
  [ -n "$name" ] || { echo "백업 없음: s3://$BUCKET/$PREFIX/" >&2; exit 1; }
fi
work=$(mktemp -d); trap '"$PG_BIN/pg_ctl" -D "$work/pg" -m fast stop >/dev/null 2>&1 || true; rm -rf "$work"' EXIT
echo "백업: $name"

aws --profile "$PROFILE" s3 cp "s3://$BUCKET/$PREFIX/$name" "$work/$name" --only-show-errors
aws --profile "$PROFILE" s3 cp "s3://$BUCKET/$PREFIX/$name.counts.json" "$work/counts.json" --only-show-errors

# 1) 체크섬
want=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sha256"])' "$work/counts.json")
got=$(shasum -a 256 "$work/$name" | cut -d' ' -f1)
[ "$want" = "$got" ] && echo "sha256: 일치" || { echo "sha256: 불일치 ($got != $want)" >&2; exit 1; }

# 2) 임시 PostgreSQL 16에 복원 (소유자 · 권한은 빼고 데이터만 비교)
"$PG_BIN/initdb" -D "$work/pg" -U postgres --auth=trust >/dev/null
"$PG_BIN/pg_ctl" -D "$work/pg" -o "-p $PORT -k $work" -l "$work/pg.log" -w start >/dev/null
"$PG_BIN/createdb" -h "$work" -p "$PORT" -U postgres gpuf_data
start=$(date +%s)
"$PG_BIN/pg_restore" -h "$work" -p "$PORT" -U postgres -d gpuf_data --no-owner --no-privileges --exit-on-error "$work/$name"
echo "복원: $(( $(date +%s) - start ))초"

# 3) 행 수 비교
"$PG_BIN/psql" -h "$work" -p "$PORT" -U postgres -d gpuf_data -X -At -c "
SELECT n.nspname || '.' || c.relname || '=' ||
       (xpath('/row/c/text()', query_to_xml(format('SELECT count(*) AS c FROM %I.%I', n.nspname, c.relname), false, true, '')))[1]::text
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE c.relkind = 'r' AND n.nspname = 'data' ORDER BY 1" >"$work/restored.txt"
python3 - "$work/counts.json" "$work/restored.txt" <<'PY'
import json, sys
want = json.load(open(sys.argv[1]))["counts"]
got = dict(l.strip().split("=", 1) for l in open(sys.argv[2]) if "=" in l)
bad = 0
for t in sorted(set(want) | set(got)):
    w, g = want.get(t), int(got[t]) if t in got else None
    ok = w == g
    bad += not ok
    print(f"{'OK ' if ok else 'DIFF'} {t:28} 백업 {w!s:>8}  복원 {g!s:>8}")
print("결과:", "통과" if not bad else f"불일치 {bad}개")
sys.exit(1 if bad else 0)
PY
