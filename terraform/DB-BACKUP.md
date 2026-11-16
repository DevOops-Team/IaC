# DB 백업용 AWS 인증·권한 (GPU-128)

DB VM `172.30.0.50`의 `db-backup` 워크로드가 S3에 백업을 업로드하는 구성이다.
기존 ADR-31 쓰기 전용 합의를 기준으로 하며, 저장소 결정은 ADR-14 통합 내용을 함께 확인한다.
network/EKS를 내려도 백업 데이터는 별도 보존 대상으로 관리한다.

## 현재 기준

- 확인일: 2026-11-16, 계정 `947027666399`, 리전 `us-east-2`.
- 역할: `devoops-prod-onprem-db-backup`.
- Roles Anywhere 프로필·인증서 CN: `devoops-prod-db-backup`.
- 새 계정 data·identity 적용 완료. 실제 백업 업로드 성공과는 별도 상태다.

## 쓰기 전용 권한

| 대상 | 허용 API | 목적 |
| --- | --- | --- |
| `backups/db/*` | `s3:PutObject` | 백업 파일 업로드 |
| 동일 | `s3:AbortMultipartUpload` | 실패한 멀티파트 업로드 취소 |
| 동일 | `s3:ListMultipartUploadParts` | 해당 업로드 조각 목록 확인 |

```text
arn:aws:s3:::devoops-prod-ckpt-947027666399-us-east-2/backups/db/*
```

`GetObject`, `ListBucket`, `DeleteObject`, 체크포인트 경로·버킷 관리 권한은 없다.
SSE-S3을 사용하므로 별도 KMS 권한을 추가하지 않는다. 백업 키에 고유 시각 등을 넣어 파일을 구분한다.
업로드 도구의 목록·다운로드 오류를 피하려고 읽기 권한을 추가하지 말고 쓰기 전용으로 동작하는지 먼저 확인한다.

## 복원

다운로드는 DB VM 역할이 아니라 관리자의 SSO 권한으로 수행한다.
담당자 Mac의 기존 `devoops`와 현재 인프라 PC의 `nochan`은 로컬 프로필 이름이므로 STS로 실제 계정·역할을 확인한다.
로컬 PostgreSQL 16에 `pg_restore` 후 운영 DB와 행 수를 비교하고 GPU-128에 결과를 기록한다.
실제 장애 복원도 관리자가 새 VM에 받아 넣는 방식이므로 DB 백업 역할에 읽기 권한을 줄 필요는 없다.

## 데이터 30일 보존

`prod/data`의 체크포인트 버킷 수명 주기 중 `backups/db/`에만 적용한다.

| 규칙 | 기준 |
| --- | --- |
| 현재 객체 만료 | 생성 후 30일 |
| 이전 버전 만료 | 이전 버전이 된 후 30일 |
| 만료된 삭제 마커 정리 | 조건에 맞는 마커 정리 |

`jobs/`, `code/`, `datasets/`에 이 30일 규칙을 적용하지 않는다.
모니터링 지표·로그·트레이스는 별도 버킷에서 앱이 보존을 관리한다.
버전 관리 버킷의 현재 객체 만료는 먼저 삭제 마커를 만들며 모든 이전 버전을 즉시 삭제하지 않는다.
수명 주기 처리도 비동기이므로 생성일부터 정확히 30일 뒤 모든 실제 데이터가 사라진다고 해석하지 않는다.
향후 같은 버킷의 규칙은 기존 단일 Terraform 수명 주기 리소스 안에 추가한다.

## 인증서 60일 발급·갱신

```powershell
./scripts/rolesanywhere/New-WorkloadCertificate.ps1 -Workload db-backup
```

기본 유효기간은 **60일**이다. 데이터 보존 30일·임시 AWS 세션 1시간과 구분한다.
CA나 사용 중인 인증서를 자동 교체하지 않고 개인 키는 Git·Terraform state 밖에 보관한다.
[온프레 AWS 인증 안내](ONPREM-AWS-IDENTITY.md)에 따라 인증서와 역할·프로필 값을 전달한다.
발급만으로 VM 설치·활성화가 끝나지는 않는다.

2026-11-16에는 기존 키와 일치하는 60일 인증서를 같은 CA로 발급해 DB VM의
`/home/db/.config/devoops/db-backup/client.pem`에 교체했다. 기존 인증서는 보관했고 키는 재전송하지 않았다.
새 인증서 만료는 **2027-01-15 14:09 KST**다.

단, `aws-config`의 `credential_process`에는 아직 이전 계정 `354363695096` ARN이 남아 있다.
새 계정의 `terraform output workloads`에서 `db-backup` 값을 확인해 연결 설정에 반영하고
새 세션·실제 업로드를 검증해야 한다. 인증서 교체를 AWS 연결 성공으로 기록하지 않는다.

## 배포·검증 범위

data·identity plan은 별도로 검토한다. 백업 작업·타이머, 인증서 설치, 업로드 검증, 복원 시험은
Terraform 자원 생성과 구분해 완료 상태를 기록한다.

### 2026-11-13 당시 검토 이력

아래는 이전 계정에서 최초 검토하던 당시 결과이며 현재 새 계정 상태를 뜻하지 않는다.

- 두 root fmt/validate, 인증서 스크립트 구문 검사 통과.
- IAM 시뮬레이션 18개 조합에서 업로드 허용 3개·범위 밖 거부 15개 확인.
- data plan: 1개 생성, 변경·삭제 없음.
- identity plan: 3개 생성·3개 변경. 변경에는 당시 실사용 백엔드 읽기 권한 제거와 EKS 조회 범위 확대가 포함되어 있었다.
- 담당자와 기존 권한 차이를 해소하기 전 전체 적용을 보류했던 이력이다. 현재 상태는 새 계정 적용 기록을 기준으로 판단한다.
