# gpu-iac — Kubernetes 실행 기반

이 저장소는 AWS Terraform과 온프레미스 Ansible/Kubespray 설정을 관리합니다.

```text
gpu-iac/
├─ bootstrap/
│  └─ certs.sh            # Roles Anywhere CA 확인 · 워크로드 인증서 발급 (기본 backend · mimir · loki · tempo, 60일)
├─ terraform/              # AWS (자세한 구조 · config 추가 방법: terraform/README.md)
│  ├─ run.sh              # state → base → eks 순서 실행 (destroy는 eks)
│  ├─ config/prod.yaml    # 사람이 고치는 값 전부 (CIDR · 버킷 규칙 · EKS 토폴로지 · 워크로드)
│  ├─ state/              # Terraform state 버킷
│  ├─ live/base/          # S3 · DynamoDB · Roles Anywhere · VPC (영속 + 기반)
│  ├─ live/eks/           # EKS · GPU 노드그룹 · 온프레 허브 등록 (켜고 끔)
│  ├─ modules/            # vpc · s3 · dynamodb · rolesanywhere(role/) · eks(role/) · eks-hub-registration
│  └─ docs/
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

구조와 config에 무엇을 어떻게 추가하는지는 [terraform/README.md](terraform/README.md).

- 계정 ID · SSO 역할 이름 · 버킷 이름은 코드에 없습니다. 실행할 때 `aws sts`로 계정을 읽고 이름을 계산합니다 (GPU-171).
- AWS 프로파일 **`devoops`** (팀 공통, 셸의 `AWS_PROFILE`은 무시, `--profile`로만 변경). 리전 · 이름 접두어는 `config/prod.yaml`.
- state는 세 개: `prod/bootstrap`(state 버킷) · `prod/base` · `prod/eks`. [Backend 안내](terraform/docs/STATE-BACKEND.md)
- 레포에 두면 안 되는 값(온프레 공인 IP)은 Git 제외 `terraform/live/base/terraform.local.tfvars`.

| 순서 | 무엇 | 만드는 것 | 필요한 것 |
| --- | --- | --- | --- |
| 0 | `bootstrap/certs.sh` | Roles Anywhere 워크로드 인증서 (60일) | 기존 CA (`~/.devoops/rolesanywhere/prod`) |
| 1 | `state` | state 버킷 | — |
| 2 | `base` | 체크포인트 · 모니터링 S3, 펜싱 DynamoDB, Roles Anywhere 역할, VPC · NAT · VPN | CA 공개 인증서, 온프레 공인 IP |
| 3 | `eks` | EKS A/B(/C) · GPU 노드그룹 · 온프레 허브 등록 | base, 온프레 kubeconfig, `--proxy` |

```shell
aws sso login --profile devoops
bootstrap/certs.sh --status                     # 인증서 만료일
terraform/run.sh plan                           # 전체 plan
terraform/run.sh apply eks --proxy              # EKS 켜기 (base 뒤)
terraform/run.sh destroy                        # EKS 끄기
terraform/run.sh output base -- workloads       # signing helper용 ARN
```

- `apply` · `destroy`는 대상 계정 ID를 입력해야 진행합니다 (`-y`로 생략).
- 새 작업은 `develop`에서 `GPU-n-설명` 브랜치 → `develop` → `main` PR (ADR-20).

## EKS GPU 관리형 노드 그룹

GPU는 EKS Managed Node Group으로 관리합니다 (Karpenter 안 씀, ADR-25). **현재 기본값은 소규모 테스트 프로필**이며, 환경/리소스 이름은 계속 prod를 사용합니다.

| 프로필 | 클러스터 | 시스템 CPU (On-Demand) | GPU (모두 Spot) |
| --- | --- | --- | --- |
| test (기본) | A / B | 각각 t3.large 1대 | 각각 학습 4대 + 예비 1대 고정 (총 10대) |
| full (최종 목표) | A / B / C | 각각 t3.large 1대 | 각각 학습 4대 + 예비 1대 고정 |

test는 `g4dn.xlarge` 10대(총 40vCPU)로 구성합니다. full은 `g4dn.xlarge`·`g4dn.2xlarge`(각 T4 1장)를 허용합니다. A/B/C의 노드는 config `eks.clusters.<x>.az_index`의 AZ(us-east-2a/b/c), EKS 제어부는 여러 AZ 서브넷을 사용합니다. 활성 GPU 그룹은 최소=희망=최대 수량으로 고정하므로 Karpenter·Cluster Autoscaler·노드 유지용 자리 표시 Pod를 사용하지 않습니다. Pod 요청만으로 GPU 노드를 추가하지 않습니다.

- 프로필: `config/prod.yaml`의 `eks.topology`(기본 test) 또는 `run.sh --topology test|full`. full→test 전환은 C 삭제와 허용 인스턴스 유형 변경을 포함할 수 있어 별도 검토가 필요합니다.
- 인프라 상한/유형/배치와 실행 전 조건: [관리형 GPU 구성·전환 안내](terraform/docs/MANAGED-GPU.md).
- NVIDIA 플러그인 설정은 `terraform/run.sh output eks -- -json gpu_bootstrap`, 클러스터별 endpoint·Pod Identity·GPU 그룹은 `terraform/run.sh output eks -- -json eks_clusters`로 전달합니다. 플러그인 설치와 Kueue·JobSet·큐/RBAC는 쿠버 담당자가 GitOps에서 관리합니다.
- 예비 그룹만 `devoops/spare=true:NoSchedule` taint를 가집니다. NVIDIA 플러그인은 GPU·예비 taint 모두 허용합니다. 일반 학습에는 예비 toleration을 주지 않습니다.
- 비용을 줄일 때는 `terraform/run.sh destroy`로 EKS를 끄고, NAT · VPN까지 끄려면 config `network.enabled: false`로 `apply base`합니다. GPU 할당량(us-east-2 G/VT Spot 40 vCPU)은 apply 전에 확인합니다.

## 장애 감지·서비스 복구

ADR-11에 따라 개인 PC에서 `ansible/playbooks/recovery/`, `ansible/scripts/recovery/`를 필요할 때 수동 실행합니다. 전용 VM·상시 복구 timer는 사용하지 않습니다. 기본은 관찰 전용이며 설치/부트스트랩 site.yml과 분리합니다. [RECOVERY.md](ansible/RECOVERY.md)를 확인합니다.

## EKS ↔ 온프레 허브 등록

EKS를 만들고 지울 때 온프레 관리 클러스터 등록(Argo CD 클러스터 Secret, MultiKueue kubeconfig, EKS의 `multikueue-sa` · `argocd-manager` · `training/ghcr-pull`)도 `terraform/eks`가 함께 만들고 지웁니다. 큐 · ApplicationSet은 Gitops가 관리합니다. [허브 등록 안내](terraform/docs/EKS-HUB-REGISTRATION.md).
