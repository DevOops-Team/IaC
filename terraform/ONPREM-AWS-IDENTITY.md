# 온프레 AWS 인증 — IAM Roles Anywhere

온프레 앱이 장기 액세스 키 대신 인증서·개인 키로 AWS 임시 자격 증명을 받는 구성이다.
인증 방법과 권한 범위는 별개이며, 역할을 받았다고 모든 AWS 작업이 허용되는 것은 아니다.

## 현재 기준

- 확인일: 2026-11-16.
- 계정 `947027666399`, 리전 `us-east-2`, 운영자 CLI 프로필 `nochan`.
- bootstrap·data·identity 적용 완료. 각 적용 후 `No changes` 확인.
- 앱별 IAM 역할·Roles Anywhere 프로필 8개 생성. 앱의 실제 요청 성공 여부는 별도 검증 대상이다.
- 새 계정 EKS는 아직 생성하지 않았다. Pod Identity·Access Entry·허브 등록의 코드와 적용 상태를 구분한다.
- 이전 계정 ARN·버킷 이름·저장된 plan을 새 계정에서 재사용하지 않는다.

## Terraform 구성과 순서

| 실행 경로 | 관리 대상 | 순서상 확인할 점 |
| --- | --- | --- |
| `prod/bootstrap` | Terraform state용 S3 | 최초 생성은 로컬 state로 진행한 뒤 새 S3로 이전 |
| `prod/data` | 체크포인트·모니터링 S3, fencing DynamoDB | 앱 실행 전 저장소 생성 |
| `prod/identity` | CA 신뢰 앵커, 앱별 역할·정책·프로필 | EKS Access Entry가 참조할 역할 먼저 생성 |
| `prod/network` | VPC·VPN·EKS, EKS 접근·허브 등록 | identity 이후 적용, 비공개 API 접근 경로 확인 |

계정·리전·이름 변경 시 Provider, backend, 역할 ARN, 버킷 이름, 앱의 `credential_process`를 함께 대조한다.
초기 실행 순서는 [state 안내](STATE-BACKEND.md) 참조. 이번 인증서 기본값 변경은 Terraform apply를 수행하지 않는다.

## 인증서 발급

스크립트는 `scripts/rolesanywhere/New-WorkloadCertificate.ps1`이다.
CA와 개인 키는 저장소 밖 `%USERPROFILE%\.devoops\rolesanywhere\prod`에 보관한다.
디렉터리 ACL은 현재 사용자와 SYSTEM으로 제한한다. 개인 키 자체는 암호화된 형식이 아니므로 PC·계정 보호도 필요하다.
CA 백업과 갱신 담당을 정하고, CA 개인 키를 Pod에 마운트하거나 전달하지 않는다.
Terraform은 공개 인증서 `ca.pem`만 읽으며 개인 키는 구성·plan·state에 넣지 않는다.

| 구분 | 기간 | 의미 |
| --- | --- | --- |
| CA | 2년 | 워크로드 인증서를 발급하는 CA의 유효기간 |
| 워크로드 인증서 | 기본 60일 | 임시 자격 증명을 요청할 때 사용하는 인증서 |
| AWS 임시 자격 증명 | 1시간 | Roles Anywhere에서 발급하는 세션 |
| 데이터 보존 | 별도 정책 | 인증서 기간 변경과 무관 |

유료 AWS Private CA는 생성하지 않는다. 기존 CA·인증서의 자동 덮어쓰기를 거부하므로 먼저 키 쌍과 만료일을 확인한다.
아래 명령은 인증서를 발급하며 Kubernetes Secret을 만들지는 않는다.

```powershell
./scripts/rolesanywhere/New-WorkloadCertificate.ps1 -Workload backend
./scripts/rolesanywhere/New-WorkloadCertificate.ps1 -Workload recovery
./scripts/rolesanywhere/New-WorkloadCertificate.ps1 -Workload relocator
./scripts/rolesanywhere/New-WorkloadCertificate.ps1 -Workload multikueue
./scripts/rolesanywhere/New-WorkloadCertificate.ps1 -Workload db-backup
./scripts/rolesanywhere/New-WorkloadCertificate.ps1 -Workload mimir -ValidityDays 60
./scripts/rolesanywhere/New-WorkloadCertificate.ps1 -Workload loki -ValidityDays 60
./scripts/rolesanywhere/New-WorkloadCertificate.ps1 -Workload tempo -ValidityDays 60
```

CN은 `devoops-prod-<workload>`이다. Mimir·Loki·Tempo는 각각 `devoops-prod-mimir`, `devoops-prod-loki`, `devoops-prod-tempo`다.
역할 신뢰 정책은 SourceAccount, 정확한 신뢰 앵커 ARN, 인증서 CN을 제한한다.
같은 CA를 사용하더라도 백엔드 인증서로 복구 역할을 받도록 허용하는 것은 아니다.

### 전달과 갱신

- 기본값을 바꿔도 기존 인증서는 연장되지 않는다. 같은 CA로 새 인증서를 발급해 별도로 교체한다.
- 갱신 시 보안이 설정된 새 `PkiDirectory`에 같은 CA를 복원해 발급하거나, 확인된 기존 키에 맞춰 명시적으로 갱신한다.
- CA 서명, CN, 키 일치, 발급·만료일 검증 후 실제 사용 경로·Secret에 원자적으로 교체한다.
- 앱 재시작·다시 읽기가 필요한지 확인하고 새 세션 발급과 허용 작업을 검증한 뒤 이전 인증서를 정리한다.
- 전달 파일은 워크로드의 `client.pem`·`client.key`로 한정한다. 개인 디렉터리로 SCP 등 합의된 방법을 사용한다.
- 각 키는 자기 워크로드만 읽기 전용으로 마운트하고 Secret·RBAC 접근도 제한한다.
- 인증서 갱신 배포·CRL 게시는 현재 자동화하지 않았다. 만료·폐기 절차는 별도 관리한다.
- 만료된 인증서는 새 세션을 받지 못한다. 이미 발급된 세션은 인증서 폐기만으로 즉시 종료되지 않으므로 세션 만료와 구분한다.
- AWS 자원 재생성 후 역할·프로필·신뢰 앵커 ARN을 다시 확인한다. 옛 state의 식별자를 재사용하지 않는다.

모니터링 3개는 60일 인증서 전달 완료 상태다. DB 백업용도 같은 CA·기존 개인 키로 60일 갱신 후 VM 사용 경로에 교체했다.
나머지 4개 워크로드의 발급·설치는 별도 확인한다. 모니터링 보존은 앱에서 관리하므로 버킷 전체의 30일 객체 만료 규칙을 추가하지 않는다.

## 앱별 역할과 권한

역할 이름은 `devoops-prod-onprem-<workload>`이며 프로필·역할을 앱마다 분리한다.

| 워크로드 | 현재 허용 범위 | 확인할 점 |
| --- | --- | --- |
| `backend` | S3 `code/`·`datasets/` 업로드, fencing `PutItem`·`GetItem` | 최초 생성 조건은 앱에서 지정 |
| `recovery` | fencing `GetItem`·`UpdateItem` | 별도 복구 테이블 권한은 현재 미포함 |
| `relocator` | fencing 조회·갱신, `code/*/jobset.json` 읽기, EKS A/B/C 조회, 오하이오 EC2 조회 | EC2 강제 종료 권한 없음 |
| `multikueue` | EKS A/B/C `DescribeCluster` | Kubernetes 객체 변경 권한과 별개 |
| `db-backup` | `backups/db/*` 업로드·멀티파트 처리 | 읽기·목록·삭제 없음. [DB 백업 안내](DB-BACKUP.md) 참조 |
| `mimir` | 모니터링 S3 `mimir/` 목록·읽기·쓰기·삭제·멀티파트 처리 | 목록은 해당 prefix 조건 |
| `loki` | 모니터링 S3 `loki/` 목록·읽기·쓰기·삭제·멀티파트 처리 | 목록은 해당 prefix 조건 |
| `tempo` | `tempo/` 관리 및 객체 태그 읽기·쓰기 | 다른 앱 prefix 접근 불가 |

실제 정책은 `environments/prod/identity/`가 정본이다. 앱 namespace·Deployment·ServiceAccount는 GitOps와 담당자 설정을 확인한다.
백엔드는 `attribute_not_exists(job_id)` 조건으로 최초 항목을 생성해야 하며, 복구·재배치는 실행 세대 등 합의된 조건으로 갱신한다.
이런 앱 조건을 IAM만으로 모두 강제하는 구조는 아니다. 진행률·사건 테이블이나 추가 EC2 API는 임의로 가정해 허용하지 않는다.

## 앱 실행 환경

공식 체크섬을 확인한 `aws_signing_helper`와 지원되는 AWS SDK/CLI를 앱 실행 환경에 준비한다.
`prod/identity`의 `terraform output workloads`에서 앱별 `credential_process`를 확인해 읽기 전용 AWS 설정 파일에 넣는다.

```ini
[profile onprem]
region = us-east-2
credential_process = <해당 워크로드 출력 명령>
```

출력 예시는 인증서 `/var/run/devoops-aws/client.pem`, 개인 키 `client.key`를 사용한다.
설정은 ConfigMap, 해당 앱의 인증서·키만 Secret으로 마운트한다.
`AWS_PROFILE=onprem`, `AWS_CONFIG_FILE`은 마운트 경로, `AWS_REGION=us-east-2`로 설정한다.
고정 `AWS_ACCESS_KEY_ID`·`AWS_SECRET_ACCESS_KEY`·`AWS_SESSION_TOKEN` 주입 방식과 구분한다.
signing helper는 임시 자격 증명을 발급받지만 인증서 자체를 갱신하지 않는다.

역할별 STS 신원·허용 작업과 다른 역할 사용·범위 밖 작업 거부를 검증한다.
갱신 뒤 새 세션 발급, 세션 만료 후 재발급도 확인한다. 실제 앱 검증 전에는 역할 생성만으로 연동 완료라고 기록하지 않는다.

## EKS API 접근과 Kubernetes RBAC

| IAM 역할 | EKS Access Entry의 Kubernetes 그룹 |
| --- | --- |
| `onprem-multikueue` | `devoops:multikueue` |
| `onprem-relocator` | `devoops:relocator` |

이 매핑만으로 Kubernetes 동작이 허용되지는 않는다. 별도의 Role/ClusterRoleBinding을 연결해야 한다.
앱 역할에는 관리자 Access Policy를 부여하지 않는다. `DescribeCluster`는 정보 조회이지 객체 생성·삭제 권한이 아니다.

현재 허브 자동 등록 코드의 MultiKueue·Argo CD는 **Kubernetes ServiceAccount 토큰**을 사용한다.
MultiKueue는 `kueue-system/multikueue-sa`, Argo CD는 `kube-system/argocd-manager`가 기준이다.
Argo CD는 현재 코드에서 CRD·웹훅 등을 배포하기 위해 `cluster-admin`을 사용한다.
모든 원격 접속이 Roles Anywhere로 처리된다고 해석하지 않는다. [허브 등록 안내](EKS-HUB-REGISTRATION.md) 참조.

EKS 재생성 시 API 주소·CA·토큰을 다시 등록한다. 재배치 실행기의 kubeconfig·RBAC는 쿠버 담당자 구현과 대조한다.
현재 허브 모듈은 relocator 전용 Secret까지 생성하지 않는다.
Roles Anywhere 기반 `aws eks get-token` 경로를 추가한다면 CLI/helper 실행 위치와 토큰 갱신을 별도로 확인한다.

## 남은 확인 사항

- `network/eks.tf`의 관리자 역할 조회 이름에 이전 SSO 역할 suffix가 남아 있다. EKS 배포 전에 새 계정 기준 수정·검증 필요.
- DB VM `/home/db/.config/devoops/db-backup/aws-config`는 이전 계정 ARN을 참조한다. 인증서 60일 교체와 별개로 연결 설정 수정·검증 필요.
- Roles Anywhere·STS의 HTTPS 접근과 비공개 EKS API의 VPN·라우팅·SG·방화벽은 각각 확인한다. 인증서가 VPN·통신 경로를 만들어 주지는 않는다.

## 참고

- [Roles Anywhere 신뢰 모델](https://docs.aws.amazon.com/rolesanywhere/latest/userguide/trust-model.html)
- [Roles Anywhere credential helper](https://docs.aws.amazon.com/rolesanywhere/latest/userguide/credential-helper.html)
- [EKS Access Entry](https://docs.aws.amazon.com/eks/latest/userguide/access-entries.html)
