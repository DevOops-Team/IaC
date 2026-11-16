# gpu-iac — Kubernetes 실행 기반

이 저장소는 AWS Terraform과 온프레미스 Ansible/Kubespray 설정을 관리합니다.

```text
gpu-iac/
├─ bootstrap/
│  └─ certs.sh            # Roles Anywhere CA 확인 · 워크로드 인증서 발급 (기본 backend · mimir · loki · tempo, 60일)
├─ terraform/
│  ├─ run.sh              # root 순서 실행: state → data → identity → vpc → eks (destroy는 eks → vpc)
│  ├─ state/              # Terraform state 버킷 (계정마다 한 번)
│  ├─ data/               # 체크포인트 · 모니터링 S3, 펜싱 DynamoDB (영속)
│  ├─ identity/           # Roles Anywhere trust anchor · 온프레 워크로드 역할
│  ├─ vpc/                # VPC · 서브넷 · NAT · 엔드포인트 · VPN
│  ├─ eks/                # EKS A/B(/C) · GPU 노드그룹 · 온프레 허브 등록
│  ├─ modules/            # eks · eks-hub-registration
│  └─ docs/               # 설계 · 운영 문서
├─ ansible/
│  ├─ inventory/onprem/   # Kubernetes VM 6대·HA·MAP 설정
│  ├─ playbooks/
│  │  ├─ infra/           # VM 준비·설치 전 검사
│  │  ├─ k8s/             # 관리 API MAP 확인
│  │  ├─ bootstrap/       # Argo CD 최초 설치·Secret·root 등록
│  │  ├─ network/         # 외부 Cloudflare DNS API
│  │  └─ site.yml         # 클러스터 설치 후 bootstrap 실행
│  └─ roles/
└─ scripts/               # pfSense VPN 인바운드 정책 · Windows용 인증서 발급
```

앱 Deployment·Service·RBAC, Traefik·cert-manager values, frontend Ingress·웹 인증서, EKS 큐·MultiKueue 연결 객체는 Gitops 레포(DevOops-Team/Gitops)가 관리합니다. 이 저장소에서 해당 리소스를 반복 적용하지 않습니다.

Cloudflare DNS-only 레코드는 bootstrap이 관리하며, HTTPS는 Gitops의 Traefik·cert-manager가 처리합니다. 공인 IP → pfSense TCP 전달 → Traefik 경로를 먼저 검증합니다. Kubernetes VM·API VIP·CoreDNS·MAP는 Kubespray가 관리합니다. Kueue·JobSet 컨트롤러는 스케줄링 파트 담당입니다.

온프레미스 실행 순서는 [ansible/PROJECT.md](ansible/PROJECT.md)를 확인합니다.

## AWS Terraform

계정 ID · SSO 역할 이름 · 버킷 이름은 코드에 없습니다. 실행할 때 `aws sts`로 계정을 읽고, 이름은
`<project>-<env>-<용도>-<account>-<region>`으로 계산합니다. 어느 계정이든 프로파일만 맞추면 그대로 적용됩니다 (GPU-171).

- AWS 프로파일: **`devoops`** (팀 공통 이름, 셸의 `AWS_PROFILE`은 쓰지 않음, `--profile`로만 변경)
- 리전 `us-east-2`, 이름 접두어 `devoops-prod`, 공통 태그 `Project=devoops` · `Environment=prod`
- root마다 state가 따로 있습니다: `s3://devoops-prod-tfstate-<account>-us-east-2/prod/<root>/terraform.tfstate` (state root만 키 이름 `bootstrap`). [Backend 안내](terraform/docs/STATE-BACKEND.md)
- 로컬 입력(공인 IP 등)은 Git에서 제외된 `<root>/terraform.local.tfvars`에 둡니다. `run.sh`가 있으면 자동으로 넘깁니다.

| 순서 | root | 만드는 것 | 필요한 것 |
| --- | --- | --- | --- |
| 0 | `bootstrap/certs.sh` | CA · 워크로드 인증서 (60일) | 기존 CA(`~/.devoops/rolesanywhere/prod`) |
| 1 | `state` | state 버킷 (없으면 로컬 state로 만들고 버킷으로 이전) | — |
| 2 | `data` | 체크포인트 · 모니터링 S3, 펜싱 DynamoDB (`prevent_destroy`) | — |
| 3 | `identity` | Roles Anywhere trust anchor · 워크로드 역할 | CA 공개 인증서 `ca.pem` |
| 4 | `vpc` | VPC · 서브넷 · NAT · S3/DynamoDB 엔드포인트 · VPN | `customer_gateway_ip` |
| 5 | `eks` | EKS A/B(/C) · GPU 노드그룹 · 온프레 허브 등록 | vpc state, 온프레 kubeconfig, SOCKS 프록시 |

```shell
aws sso login --profile devoops
bootstrap/certs.sh --status                     # 인증서 만료일
terraform/run.sh plan                           # 전체 plan (순서대로)
terraform/run.sh apply vpc eks --proxy          # 고른 root만, 순서는 자동
terraform/run.sh apply eks --topology full --proxy
terraform/run.sh destroy                        # eks → vpc (data · identity · state는 남김)
terraform/run.sh output identity -- workloads   # signing helper용 ARN
terraform/run.sh validate                       # 자격 증명 없이 문법 검사 (CI와 같음)
```

- `apply` · `destroy`는 대상 계정 ID를 입력해야 진행합니다 (`-y`로 생략).
- `identity`의 IAM 역할은 `eks`의 Access Entry보다 먼저 있어야 합니다(순서로 보장).
- 새 작업은 `develop`에서 `GPU-n-설명` 브랜치 → `develop` → `main` PR (ADR-20).

## EKS GPU 관리형 노드 그룹

GPU는 EKS Managed Node Group으로 관리합니다 (Karpenter 안 씀, ADR-25). **현재 기본값은 소규모 테스트 프로필**이며, 환경/리소스 이름은 계속 prod를 사용합니다.

| 프로필 | 클러스터 | 시스템 CPU (On-Demand) | GPU (모두 Spot) |
| --- | --- | --- | --- |
| test (기본) | A / B | 각각 t3.large 1대 | A: 학습 2대 고정 / B: 0대 |
| full (최종 목표) | A / B / C | 각각 t3.large 1대 | 각각 학습 4대 + 예비 1대 고정 |

test는 `g4dn.xlarge` 2대(총 8vCPU)만 허용합니다. full은 `g4dn.xlarge`·`g4dn.2xlarge`(각 T4 1장)를 허용합니다. A/B/C의 CPU 노드는 vpc 서브넷 AZ(정렬 기준) 1 · 2 · 3번째(us-east-2a/b/c), EKS 제어부는 여러 AZ 서브넷을 사용합니다. 활성 GPU 그룹은 최소=희망=최대 수량으로 고정하므로 Karpenter·Cluster Autoscaler·노드 유지용 자리 표시 Pod를 사용하지 않습니다. test B는 GPU 그룹 자체가 없으며 Pod 요청만으로 GPU를 만들지 않습니다.

- 프로필: `terraform/eks/topology-test.tfvars` 또는 `topology-full.tfvars`. `run.sh --topology test|full`로 고릅니다. full→test 전환은 C와 예비 그룹 삭제/축소를 포함할 수 있어 별도 검토가 필요합니다.
- 인프라 상한/유형/배치와 실행 전 조건: [관리형 GPU 구성·전환 안내](terraform/docs/MANAGED-GPU.md).
- NVIDIA 플러그인 설정은 `terraform/run.sh output eks -- -json gpu_bootstrap`, 클러스터별 endpoint·Pod Identity·GPU 그룹은 `terraform/run.sh output eks -- -json eks_clusters`로 전달합니다. 플러그인 설치와 Kueue·JobSet·큐/RBAC는 쿠버 담당자가 GitOps에서 관리합니다.
- 예비 그룹만 `devoops/spare=true:NoSchedule` taint를 가집니다. NVIDIA 플러그인은 GPU·예비 taint 모두 허용합니다. 일반 학습에는 예비 toleration을 주지 않습니다.
- 비용을 줄일 때는 `terraform/run.sh destroy`(eks → vpc)로 끄고 `apply vpc eks`로 다시 켭니다. GPU 할당량(us-east-2 G/VT Spot 40 vCPU)은 apply 전에 확인합니다.

## 장애 감지·서비스 복구

ADR-11에 따라 개인 PC에서 `ansible/playbooks/recovery/`, `ansible/scripts/recovery/`를 필요할 때 수동 실행합니다. 전용 VM·상시 복구 timer는 사용하지 않습니다. 기본은 관찰 전용이며 설치/부트스트랩 site.yml과 분리합니다. [RECOVERY.md](ansible/RECOVERY.md)를 확인합니다.

## EKS ↔ 온프레 허브 등록

EKS를 만들고 지울 때 온프레 관리 클러스터 등록(Argo CD 클러스터 Secret, MultiKueue kubeconfig, EKS의 `multikueue-sa` · `argocd-manager` · `training/ghcr-pull`)도 `terraform/eks`가 함께 만들고 지웁니다. 큐 · ApplicationSet은 Gitops가 관리합니다. [허브 등록 안내](terraform/docs/EKS-HUB-REGISTRATION.md).
