# Terraform state backend

계정 · 프로파일을 코드에 적지 않는다 (GPU-171). `terraform/run.sh`가 실행할 때 `aws sts get-caller-identity`로
계정 ID를 읽어 state 버킷 이름과 backend 설정을 만든다. 각 root의 `backend.tf`는 빈 `backend "s3" {}`이다.

| 항목 | 값 |
| --- | --- |
| 버킷 | `<project>-<env>-tfstate-<account>-<region>` (예: `devoops-prod-tfstate-947027666399-us-east-2`). 학습 체크포인트 버킷과 별개 |
| 키 | `<env>/<root>/terraform.tfstate`. `state` root만 처음 이름을 유지해 `prod/bootstrap/terraform.tfstate` |
| 잠금 | S3 native lock (`use_lockfile = true`), root마다 `.tflock` 객체. DynamoDB 잠금 테이블 없음 |
| 인증 | AWS 프로파일 `devoops` (`run.sh --profile`로만 변경). backend와 provider가 같은 프로파일을 쓴다 |

| root | state 키 | 비고 |
| --- | --- | --- |
| state | prod/bootstrap/terraform.tfstate | 버킷 자체. 버킷이 없으면 `run.sh apply state`가 로컬 state로 만든 뒤 버킷으로 이전한다 |
| live/base | prod/base/terraform.tfstate | S3 · DynamoDB · Roles Anywhere (prevent_destroy) + VPC |
| live/eks | prod/eks/terraform.tfstate | EKS · 허브 등록. base 출력을 `terraform_remote_state`로 읽는다 |
| (data · identity) | prod/data · prod/identity | 11/16 base로 합치기 전 키. 아래 "예전 state 정리" 뒤 비게 된다. 버킷 정책은 기록 보호를 위해 남긴다 |

잠금은 root끼리 서로를 막지 않는다. root 순서(`state → base → eks`)는 `run.sh`가 지키고,
여러 root를 동시에 바꾸지 않는다.

## 버킷 보호

버전 관리, SSE-S3(AES256), HTTPS 전용 정책, Block Public Access, BucketOwnerEnforced, `force_destroy = false`,
`prevent_destroy`. 버킷 정책은 위 state 키들의 DeleteObject · DeleteObjectVersion을 막고 잠금 파일 삭제는 허용한다.
만료 규칙은 없다. SSO AdministratorAccess는 정책 자체를 바꿀 수 있으므로 실수 방지용이지 불변 백업은 아니다.

state와 plan 파일에는 VPN 사전 공유 키, 허브 등록 토큰 같은 민감한 값이 들어간다. 애플리케이션 역할에 이 버킷
권한을 주지 않고, state · plan을 Git이나 로그로 공유하지 않는다.

## 새 계정에 처음 올릴 때

1. `aws sso login --profile devoops` 후 `aws sts get-caller-identity --profile devoops`로 계정 확인
2. `terraform/run.sh apply state` — 버킷이 없으면 `state/zz_local_backend_override.tf`(로컬 backend)로 버킷을 만들고,
   override를 지운 뒤 `init -migrate-state`로 state를 버킷에 옮긴다. 로컬 state 파일은 이전 후 지운다
3. `terraform/run.sh apply base` — CA 공개 인증서(`bootstrap/certs.sh`)와 온프레 공인 IP가 필요하다.
   새 계정이면 `live/base/imports.tf`(11/16 이전 1회용)를 지우고 실행한다
4. `terraform/run.sh apply eks --proxy`

이미 있는 계정에서는 `run.sh`가 매번 `init -reconfigure`로 현재 계정의 버킷을 가리킨다. 다른 계정의 `.terraform`
캐시가 남아 있어도 이 단계에서 덮어쓴다. 저장해 둔 옛 plan은 다시 쓰지 않는다.

## 수동으로 init할 때 (run.sh 없이)

```shell
ACCOUNT=$(aws sts get-caller-identity --profile devoops --query Account --output text)
export AWS_PROFILE=devoops
terraform -chdir=terraform/live/base init -reconfigure \
  -backend-config="bucket=devoops-prod-tfstate-$ACCOUNT-us-east-2" \
  -backend-config="key=prod/base/terraform.tfstate" \
  -backend-config="region=us-east-2" -backend-config="encrypt=true" -backend-config="use_lockfile=true"
```

state 이전 중에는 `-force-copy`, `state push -force`, 잠금 수동 삭제를 쓰지 않는다 (`run.sh`는 버킷이 처음 생길 때의
로컬 → S3 이전에만 `-force-copy`를 쓴다).

## 예전 state 정리 (11/16 구조 변경, 1회)

예전 `data` · `identity` root의 자원 38개를 `live/base`가 import로 넘겨받는다. 실제 AWS 자원은 바뀌지 않는다.

1. `terraform/run.sh plan base` → `38 to import, 0 to change, 0 to destroy` 확인 (+ network.enabled면 VPC 생성분)
2. `terraform/run.sh apply base` → import (+ VPC 생성)
3. `terraform/run.sh plan base` → import 없이 No changes인지 확인 후 `live/base/imports.tf` 삭제 · 커밋
4. 예전 state에서 기록만 지운다 (**destroy 금지**, 자원은 base가 관리 중):
   ```shell
   d=$(mktemp -d) && printf 'terraform {\n  backend "s3" {}\n}\n' > "$d/backend.tf"
   for k in data identity; do
     terraform -chdir="$d" init -reconfigure -input=false \
       -backend-config="bucket=devoops-prod-tfstate-$ACCOUNT-us-east-2" -backend-config="key=prod/$k/terraform.tfstate" \
       -backend-config="region=us-east-2" -backend-config="use_lockfile=true"
     terraform -chdir="$d" state list | xargs terraform -chdir="$d" state rm
   done
   ```
   state 객체는 버킷 정책으로 삭제가 막혀 있어 빈 state로 남고, 버전 기록으로 되돌릴 수 있다.

## 확인

- 적용한 root마다 S3에 state 키와 버전 기록이 있다
- `terraform/run.sh plan state base`가 계정이 같은 한 No changes
- 옛 state 버전으로 되돌리는 것은 실제 AWS 자원과 대조해 검토한 뒤에만 한다

참고: https://developer.hashicorp.com/terraform/language/backend/s3 · https://developer.hashicorp.com/terraform/cli/commands/init
