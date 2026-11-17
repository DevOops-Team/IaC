# role db-backup (GPU-181 · GPU-128)

데이터 DB VM(`inventory/db`)의 PostgreSQL `gpuf_data`를 매일 04:00 KST에 `pg_dump -Fc`로 떠서
S3 체크포인트 버킷 `backups/db/`에 올린다 (ADR-14 — 원래 ADR-31, 보관 30일은 버킷 수명 주기 규칙).

```sh
aws sso login --profile devoops
ansible-playbook -i inventory/db playbooks/data/db-backup.yml -K -e db_backup_run_now=true
```

| 설치하는 것 | 내용 |
| --- | --- |
| `/root/.aws/config` `[profile db-backup]` | `credential_process` = aws_signing_helper + 인증서 + Terraform 출력의 trust anchor · profile · role ARN |
| `/opt/db-backup/backup.sh` | 덤프와 **같은 스냅숏**의 표별 행 수(`<덤프>.counts.json`)를 같이 올림. 기본 버킷 = Terraform `checkpoint_bucket.name` |
| `gpuf-db-backup.service` · `.timer` | 매일 04:00 KST (+5분 이내), VM이 꺼져 놓치면 켜진 뒤 한 번 |

값을 손으로 넣지 않는다: 11/16 계정 이전 · identity 재생성 때 손으로 넣은 anchor · profile ID와 버킷이 어긋나 업로드가 실패했다 (GPU-179).

## 권한

- 역할 `devoops-prod-onprem-db-backup`: `backups/db/*`에 **쓰기만** (PutObject · 멀티파트). 읽기 · 목록 · 삭제 없음
- 그래서 VM에서 백업을 내려받을 수 없다. 복원 시험 · 실제 복원은 관리자 SSO로 받는다 (아래)

## 인증서 갱신 (30일)

- 지금 인증서 만료: **2026-12-13 12:26 KST**. 플레이북이 7일 전부터 경고한다
- 발급: `scripts/rolesanywhere/New-WorkloadCertificate.ps1 -Workload db-backup` (CA 키가 있는 PC, CN `devoops-prod-db-backup`)
- 넣기: `client.pem` · `client.key`를 VM `/tmp`에 scp → `sudo install -m 644 /tmp/client.pem /etc/devoops-aws/client.pem`,
  `sudo install -m 600 /tmp/client.key /etc/devoops-aws/client.key` → `/tmp` 사본 지움 (`shred -u`)
- 확인: `sudo aws --profile db-backup sts get-caller-identity` 또는 플레이북을 `-e db_backup_run_now=true`로

## aws_signing_helper

관리 클러스터 sidecar와 같은 버전(1.8.6, K8s `aws-signing-helper/` 태그 커밋 소스 빌드)을 쓴다.
다르면 플레이북이 경고한다. 바꿀 때: 이미지 `ghcr.io/devoops-team/aws-signing-helper`에서 `/usr/local/bin/aws_signing_helper`를 꺼내
`-e db_backup_signing_helper_src=<파일>`로 실행 (GPU-182).

## 복원 시험 (맥, 관리자)

```sh
aws sso login --profile devoops
sh ansible/roles/db-backup/files/restore_test.sh      # 최신 백업 → sha256 → 임시 PostgreSQL 16에 복원 → 행 수 비교 → 지움
```

결과는 GPU-128에 기록. 실제 장애 복원은 새 VM에 관리자가 받아 넣고 Data `db/001`~`005` SQL의 역할 · 권한을 다시 적용한 뒤
`pg_restore --role=data_app`.
