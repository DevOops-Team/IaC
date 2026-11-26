# terraform

AWS 인프라. **값은 `config/prod.yaml` 한 곳에서 고치고**, 코드는 리소스 종류별 모듈로 나뉘어 있다.
계정 ID · 프로파일은 코드에 없다. 실행은 `run.sh`로 한다 (GPU-171).

```text
terraform/
├─ run.sh                    state → base → eks 순서 실행 (프로파일 devoops, 계정 ID는 aws sts로)
├─ config/prod.yaml          사람이 고치는 값 전부
├─ state/                    ① Terraform state 버킷 (계정마다 한 번)
├─ live/                     실행 단위 (state 파일 하나씩)
│  ├─ base/                  ② 영속 + 기반: S3 · DynamoDB · Roles Anywhere · VPC   state 키 prod/base
│  │  ├─ storage.tf             module checkpoint · monitoring (s3), fencing · recovery (dynamodb)
│  │  ├─ onprem-roles.tf        온프레 워크로드별 AWS 권한 → module rolesanywhere
│  │  └─ network.tf             module vpc (config network.enabled)
│  └─ eks/                   ③ 켜고 끄는 것: EKS · GPU 노드그룹 · 온프레 허브 등록   state 키 prod/eks
│     ├─ clusters.tf            config 토폴로지의 클러스터마다 module eks
│     └─ hub.tf                 module eks-hub-registration (Argo CD · MultiKueue 등록)
├─ modules/                  리소스 종류별 (각 모듈 안은 리소스 하나 = 파일 하나)
│  ├─ vpc/                   vpc · subnet · igw · nat · route · endpoint · vpn
│  ├─ s3/                    bucket · policy · lifecycle
│  ├─ dynamodb/              table
│  ├─ rolesanywhere/         trust-anchor · roles  └─ role/  워크로드 IAM 역할 + profile + 정책
│  ├─ eks/                   cluster · nodes-cpu · nodes-gpu · addons · access · pod-identity · roles
│  │                         └─ role/  서비스 IAM 역할 (클러스터 · 노드 · CNI · trainer)
│  └─ eks-hub-registration/  EKS 안 SA · 토큰, 온프레 Argo CD · MultiKueue Secret
└─ docs/                     설계 · 운영 문서
```

Terraform은 하위 폴더의 `.tf`를 자동으로 읽지 않는다. `role/`은 부모 모듈이 `module "..." { source = "./role" }`로
부르는 하위 모듈이다.

## 실행

```shell
aws sso login --profile devoops
terraform/run.sh plan                          # state → base → eks
terraform/run.sh apply base                    # S3 · DynamoDB · Roles Anywhere · VPC
terraform/run.sh apply eks --proxy             # EKS (base 뒤, SOCKS 프록시 · 온프레 kubeconfig 필요)
terraform/run.sh apply eks --topology full --proxy
terraform/run.sh destroy                       # eks만 지운다 (지우기 전에 eks_gate fence로 펜싱)
terraform/run.sh output base -- workloads      # signing helper용 ARN
terraform/run.sh validate                      # 자격 증명 없이 문법 (CI와 같음)
```

| 필요한 것 | 어디서 |
| --- | --- |
| CA 공개 인증서 (base) | `~/.devoops/rolesanywhere/prod/ca.pem` 또는 `CA_CERT=` (`bootstrap/certs.sh`) |
| 온프레 공인 IP (base, network.enabled) | `live/base/terraform.local.tfvars`의 `customer_gateway_ip` (Git 제외) |
| 온프레 kubeconfig (eks) | `~/.kube/devoops-onprem.yaml` 또는 `ONPREM_KUBECONFIG=` |
| SOCKS 프록시 (eks) | `--proxy` (ssh -D 1080 k8s-master1) |
| destroy 전 펜싱 (eks) | K8s 레포 `scheduling/ops/eks_gate.py` (`K8S_REPO=`, 기본은 이 레포 옆 `K8s`), kubernetes 패키지가 있는 `PYTHON=`, 온프레 kubeconfig current-context = 관리 클러스터. 못 쓸 때만 `--skip-fence` |

복구 컨트롤러 전용 DynamoDB 테이블은 base에서 기존 펜싱 테이블과 별도로 관리한다.
`terraform/run.sh plan base`로 변경을 검토한 다음 `terraform/run.sh apply base`로 생성한다.
`terraform/run.sh output base -- recovery_table`에서 이름과 ARN을 확인하고, 이름을 복구 컨트롤러의
`recovery_table` 설정에 전달한다. 이미 같은 이름의 테이블이 있으면 먼저 Terraform state로 인계한다.

## config에 추가하는 방법 (`config/prod.yaml`)

| 하고 싶은 것 | 고칠 곳 | 실행 |
| --- | --- | --- |
| 네트워크 끄기 · 켜기 (NAT · VPN 과금) | `network.enabled` (끄기 전에 `destroy eks`) | `apply base` |
| 서브넷 · CIDR 바꾸기 | `network.cidr` · `network.subnets` | `apply base` (교체 · 재생성 주의) |
| EKS 규모 바꾸기 | `eks.topology` 또는 `--topology`, 수량은 `eks.topologies.<이름>.gpu` | `apply eks` |
| EKS 클러스터 하나 더 (`d`) | `eks.clusters.d` + 토폴로지의 `clusters` · `gpu`. `live/eks/hub.tf`에 provider · `hub_eks_d` 한 쌍 추가 (provider는 for_each 불가) | `apply eks` |
| 버킷 수명 주기 규칙 | `storage.<버킷>.lifecycle_rules` | `apply base` |
| 버킷 하나 더 | `storage`에 항목 + `live/base/storage.tf`에 `module "<이름>" { source = "../../modules/s3" ... }` | `apply base` |
| 온프레 워크로드 하나 더 | `onprem_workloads`에 이름 + `live/base/onprem-roles.tf`에 정책, 인증서 `bootstrap/certs.sh <이름>` | `apply base` |

## 비용 알림 (GPU-158)

매일 한국 시간 오전 9시 Slack 비용 요약은 별도 `live/cost` root로 관리한다.
기존 `run.sh`의 기본 실행·EKS 종료 대상에는 포함하지 않는다.
[구성·비밀 입력·배포·검증](docs/DAILY-COST-SLACK.md)을 따른다.

## 영속 자원 보호

S3 버킷 · DynamoDB 테이블 · Roles Anywhere trust anchor에는 `prevent_destroy`가 있어 `destroy base`는 실패한다.
비용이 드는 것(EKS, NAT · VPN)은 `destroy eks`와 `network.enabled: false`로 끈다.

## 2026-11-16 구조 변경 (GPU-171)

예전 root `data` · `identity`의 자원(S3 13개 + Roles Anywhere 25개)은 11/16 `import` 블록으로 `live/base`가 넘겨받았다 (import 38 · 변경 0, 이후 imports.tf 삭제)
(plan: 38 import, 0 change). 넘겨받은 뒤 순서는 [docs/STATE-BACKEND.md](docs/STATE-BACKEND.md) "예전 state 정리".
