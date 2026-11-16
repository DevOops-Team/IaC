#!/usr/bin/env bash
# 온프레 워크로드가 IAM Roles Anywhere로 AWS에 붙을 때 쓰는 클라이언트 인증서를 발급한다 (GPU-171, GPU-156).
# Terraform base root보다 먼저 실행한다: base의 Roles Anywhere trust anchor가 여기의 CA 공개 인증서(ca.pem)를 믿는다.
#
#   기본 대상: backend mimir loki tempo   (그 밖: recovery relocator multikueue db-backup)
#   유효기간: 60일 (--days로 바꿈)        CN: <project>-<env>-<workload>  (base 역할 trust 조건과 같음)
#
#   PKI 디렉터리(기본 ~/.devoops/rolesanywhere/prod, 레포 밖, 권한 700)
#     ca.key  ca.pem                         CA (2년). ca.key는 이 PC 밖으로 내보내지 않는다
#     <workload>/client.key  client.pem      워크로드에 넘기는 것은 이 두 파일뿐
#
# 사용:
#   bootstrap/certs.sh                       # 기본 4개. 이미 있는 인증서는 건너뛴다
#   bootstrap/certs.sh --renew mimir         # 같은 키로 인증서만 다시 발급 (옛 인증서는 .bak으로 보관)
#   bootstrap/certs.sh --init-ca             # CA가 없을 때만: 새 CA를 만든다
#   bootstrap/certs.sh --status              # 발급된 인증서와 만료일만 본다
#
# 새 CA를 만들고 base를 apply하면 trust anchor가 새 CA로 바뀌어, 옛 CA로 발급한 인증서
# (다른 PC에서 발급한 것 포함)는 모두 쓸 수 없게 된다. 이미 CA가 있으면 그 ca.key · ca.pem을
# 이 PKI 디렉터리로 안전하게 복사해 쓴다. Windows용 같은 동작: scripts/rolesanywhere/New-WorkloadCertificate.ps1
set -euo pipefail

ALLOWED="backend recovery relocator multikueue db-backup mimir loki tempo"
DEFAULT="backend mimir loki tempo"
DAYS=60
CA_DAYS=730
PROJECT="${PROJECT:-devoops}"
ENVIRONMENT="${ENVIRONMENT:-prod}"
PKI_DIR="${PKI_DIR:-$HOME/.devoops/rolesanywhere/$ENVIRONMENT}"
OPENSSL="${OPENSSL:-openssl}"
INIT_CA=0 RENEW=0 STATUS=0 WORKLOADS=()

die() { echo "error: $*" >&2; exit 1; }
usage() { sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
in_list() { local x="$1"; shift; for y in "$@"; do [ "$x" = "$y" ] && return 0; done; return 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --days) DAYS="${2:-}"; shift 2 ;;
    --pki-dir) PKI_DIR="${2:-}"; shift 2 ;;
    --init-ca) INIT_CA=1; shift ;;
    --renew) RENEW=1; shift ;;
    --status) STATUS=1; shift ;;
    -h|--help) usage 0 ;;
    -*) die "알 수 없는 옵션: $1" ;;
    *) in_list "$1" $ALLOWED || die "알 수 없는 워크로드: $1 ($ALLOWED)"; WORKLOADS+=("$1"); shift ;;
  esac
done
[ ${#WORKLOADS[@]} -gt 0 ] || read -r -a WORKLOADS <<<"$DEFAULT"
case "$DAYS" in ''|*[!0-9]*) die "--days는 1~365 숫자" ;; esac
[ "$DAYS" -ge 1 ] && [ "$DAYS" -le 365 ] || die "--days는 1~365"
command -v "$OPENSSL" >/dev/null || die "openssl이 없습니다"

# 개인 키는 레포 밖에만 둔다
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
case "$PKI_DIR" in /*) ;; *) PKI_DIR="$PWD/$PKI_DIR" ;; esac
probe="$PKI_DIR"; while [ ! -d "$probe" ]; do probe="$(dirname "$probe")"; done
case "$(cd "$probe" && pwd -P)/" in "$REPO_DIR/"*) die "PKI 디렉터리가 레포 안입니다: ${PKI_DIR}" ;; esac
mkdir -p "$PKI_DIR"
PKI_DIR="$(cd "$PKI_DIR" && pwd -P)"
chmod 700 "$PKI_DIR"
umask 077

CA_KEY="$PKI_DIR/ca.key" CA_CERT="$PKI_DIR/ca.pem"
expiry() { "$OPENSSL" x509 -in "$1" -noout -enddate | cut -d= -f2; }

if [ "$STATUS" -eq 1 ]; then
  [ -f "$CA_CERT" ] && echo "CA        만료 $(expiry "$CA_CERT")  ${CA_CERT}" || echo "CA        없음 (${CA_CERT})"
  for w in $ALLOWED; do
    c="$PKI_DIR/$w/client.pem"
    [ -f "$c" ] || continue
    s="유효"; "$OPENSSL" x509 -in "$c" -noout -checkend 0 >/dev/null || s="만료됨"
    "$OPENSSL" x509 -in "$c" -noout -checkend $((14*86400)) >/dev/null || [ "$s" = 만료됨 ] || s="14일 안에 만료"
    printf '%-10s %s  만료 %s\n' "$w" "$s" "$(expiry "$c")"
  done
  exit 0
fi

# ---------- CA ----------
if [ -f "$CA_KEY" ] && [ -f "$CA_CERT" ]; then
  echo "CA: 기존 사용 (만료 $(expiry "$CA_CERT"))"
elif [ -f "$CA_KEY" ] || [ -f "$CA_CERT" ]; then
  die "ca.key · ca.pem 중 하나만 있습니다. CA를 새로 만들지 말고 원본을 복구하세요 (${PKI_DIR})"
else
  [ "$INIT_CA" -eq 1 ] || die "CA가 없습니다 (${PKI_DIR}). 기존 CA가 있으면 ca.key · ca.pem을 이 디렉터리로 복사하고, 정말 새로 만들 때만 --init-ca"
  cfg="$(mktemp)"; trap 'rm -f "$cfg"' EXIT
  cat > "$cfg" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3_ca
prompt = no
[dn]
O = DevOops
CN = DevOops-Prod-Workload-CA
[v3_ca]
basicConstraints = critical,CA:TRUE,pathlen:0
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
EOF
  "$OPENSSL" req -x509 -newkey rsa:3072 -nodes -sha256 -days "$CA_DAYS" -config "$cfg" \
    -keyout "$CA_KEY" -out "$CA_CERT" 2>/dev/null
  echo "CA: 새로 만듦 (${CA_DAYS}일). base를 apply하면 trust anchor가 이 CA로 바뀝니다"
fi
"$OPENSSL" x509 -in "$CA_CERT" -noout -checkend $((DAYS*86400)) >/dev/null \
  || die "CA가 ${DAYS}일 안에 만료됩니다. CA 갱신이 먼저입니다"

# ---------- 워크로드 ----------
ext="$(mktemp)"
trap 'rm -f "$ext" "${cfg:-}"' EXIT
cat > "$ext" <<'EOF'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=clientAuth
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer
EOF

issued=() skipped=()
for w in "${WORKLOADS[@]}"; do
  dir="$PKI_DIR/$w" key="$PKI_DIR/$w/client.key" cert="$PKI_DIR/$w/client.pem" csr="$PKI_DIR/$w/client.csr"
  mkdir -p "$dir"
  if [ -f "$cert" ] && [ "$RENEW" -eq 0 ]; then
    skipped+=("$w (만료 $(expiry "$cert"))"); continue
  fi
  if [ -f "$cert" ]; then
    cp -p "$cert" "$cert.$(date +%Y%m%d%H%M%S).bak"
  fi
  if [ -f "$key" ]; then
    "$OPENSSL" req -new -key "$key" -sha256 -subj "/O=DevOops/CN=$PROJECT-$ENVIRONMENT-$w" -out "$csr"
  else
    "$OPENSSL" req -new -newkey rsa:3072 -nodes -sha256 -subj "/O=DevOops/CN=$PROJECT-$ENVIRONMENT-$w" \
      -keyout "$key" -out "$csr" 2>/dev/null
  fi
  "$OPENSSL" x509 -req -in "$csr" -CA "$CA_CERT" -CAkey "$CA_KEY" -set_serial "0x$("$OPENSSL" rand -hex 16)" \
    -days "$DAYS" -sha256 -extfile "$ext" -out "$cert.new" 2>/dev/null
  "$OPENSSL" verify -CAfile "$CA_CERT" "$cert.new" >/dev/null || die "$w 인증서 검증 실패"
  mv "$cert.new" "$cert"
  rm -f "$csr"
  chmod 600 "$key" "$cert"
  issued+=("$w (만료 $(expiry "$cert"))")
done

echo
[ ${#issued[@]} -eq 0 ] || { echo "발급 (${DAYS}일):"; printf '  %s\n' "${issued[@]}"; }
[ ${#skipped[@]} -eq 0 ] || { echo "건너뜀 (이미 있음, 다시 받으려면 --renew):"; printf '  %s\n' "${skipped[@]}"; }
cat <<EOF

다음:
  1. Terraform base: CA_CERT=$CA_CERT terraform/run.sh apply base
  2. 워크로드마다 client.pem · client.key만 안전한 경로로 넘긴다 (ca.key는 넘기지 않음)
     역할 · profile · trust anchor ARN: terraform/run.sh output base -- workloads
  3. 만료 전에 --renew로 다시 발급하고 Secret을 바꾼다 (--status로 만료일 확인)
EOF
