# gpu-iac — Kubernetes 실행 기반

이 저장소는 AWS Terraform과 온프레미스 Ansible/Kubespray 설정을 관리합니다.

```text
gpu-iac/
├─ terraform/             # AWS prod 네트워크·VPN·EKS 코드 및 재사용 모듈
├─ ansible/
│  ├─ inventory/onprem/   # Kubernetes VM 6대·HA·MAP 설정
│  ├─ playbooks/
│  │  ├─ infra/           # VM 준비·설치 전 검사
│  │  ├─ k8s/             # 관리 API MAP 확인
│  │  ├─ bootstrap/       # Argo CD 최초 설치·Secret·root 등록
│  │  ├─ network/         # 외부 Cloudflare DNS API
│  │  └─ site.yml         # 클러스터 설치 후 bootstrap 실행
│  └─ roles/
└─ .vscode/               # 이 폴더용 설정·구문 검사 task
```

앱 Deployment·Service·RBAC, Traefik·cert-manager values, frontend Ingress·웹 인증서, EKS 큐·MultiKueue 연결 객체는 형제 폴더 gpu-k8s로 이동했습니다. 이 저장소에서 해당 리소스를 반복 적용하지 않습니다.

Cloudflare DNS-only 레코드는 bootstrap이 관리하며, HTTPS는 gpu-k8s의 Traefik·cert-manager가 처리합니다. 공인 IP → pfSense TCP 전달 → Traefik 경로를 먼저 검증합니다. Kubernetes VM·API VIP·CoreDNS·MAP는 Kubespray가 관리합니다. Kueue·JobSet 컨트롤러는 스케줄링 파트 담당입니다.

실행 순서는 [ansible/PROJECT.md](ansible/PROJECT.md)를 확인합니다. 두 폴더를 각각 VS Code로 열어 사용할 수 있고, *.code-workspace는 각 폴더만 포함합니다.

## AWS Terraform

- 실행 폴더: `terraform/environments/prod/network`
- 재사용 EKS 모듈: `terraform/modules/eks`
- 이름 접두어: `devoops-prod`, 공통 태그: `Project=devoops`, `Environment=prod`
- 리전: `us-east-2`, 로컬 AWS SSO 프로필: `devoops`
- 공인 IP 등 로컬 입력은 Git에서 제외된 `terraform.local.tfvars`로 전달합니다.
- `prod` 기반 인프라 배포와 온프레미스에서 비공개 EKS API 접속을 2026-11-06에 검증했습니다. CPU 노드 1대가 `Ready`입니다.
- 영속 데이터: `terraform/environments/prod/data` (S3·fencing).
- state 전용 저장소는 `terraform/environments/prod/bootstrap`에서 관리합니다. 네 실행 폴더는 각각 S3 state와 잠금을 사용합니다. [Backend 안내](terraform/STATE-BACKEND.md)
- 온프레 인증: `terraform/environments/prod/identity` (Roles Anywhere). [설정·배포 경계](terraform/ONPREM-AWS-IDENTITY.md).
- `identity`의 IAM 역할은 `network`의 EKS Access Entry보다 먼저 생성해야 합니다. 워크로드 인증서 배포와 Kubernetes RBAC 연결은 후속 단계입니다.
- Terraform과 이후 IaC 변경은 `develop`에 먼저 푸시합니다. `develop`에서 `main`으로 가는 PR에 `so1ky`를 리뷰어로 요청하고 승인 후 머지합니다.

```shell
cd terraform/environments/prod/network
terraform init -backend-config="../../../backends/prod/network.s3.tfbackend"
terraform validate
terraform plan -var-file="terraform.local.tfvars"
```

## EKS A GPU 노드 설정

AWS 기반은 `terraform/environments/prod/network`에서 관리합니다. Karpenter 1.15.1 컨트롤러는 기존 시스템 CPU 노드에 배치합니다. GPU NodePool은 프라이빗 서브넷에서 `g4dn.xlarge` Spot을 필요할 때 생성하며, 한도는 GPU 2장과 8 vCPU입니다. EC2 중단 이벤트는 EventBridge에서 SQS로 전달합니다.

AWS 기반 배포 후, **프라이빗 EKS API에 닿는 운영 환경**에서 아래 순서로 설치합니다. Terraform을 실행한 PC와 설치 환경이 다르면 `terraform output -json karpenter_gpu` 결과를 설치 환경으로 전달합니다.

```powershell
# prod/network에서 실행. 다른 운영 환경으로 전달할 때는 아래 JSON을 저장해 읽습니다.
$raw = terraform output -json karpenter_gpu
if ($LASTEXITCODE -ne 0) { throw 'Karpenter output unavailable' }
$gpu = ($raw -join "`n") | ConvertFrom-Json
$context = $gpu.cluster_name
aws eks update-kubeconfig --profile devoops --region us-east-2 --name $gpu.cluster_name --alias $context
if ($LASTEXITCODE -ne 0) { throw 'EKS kubeconfig unavailable' }
kubectl --context $context get --raw=/readyz
if ($LASTEXITCODE -ne 0) { throw 'Private EKS API unavailable' }

$gpu.controller_values | helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter --kube-context $context --namespace $gpu.namespace --version $gpu.karpenter_version --values - --wait
if ($LASTEXITCODE -ne 0) { throw 'Karpenter installation failed' }

$gpu.device_plugin_values | helm upgrade --install nvidia-device-plugin nvidia-device-plugin --repo https://nvidia.github.io/k8s-device-plugin --kube-context $context --namespace $gpu.namespace --version $gpu.device_plugin_version --values - --wait
if ($LASTEXITCODE -ne 0) { throw 'NVIDIA device plugin installation failed' }

$gpu.manifests | kubectl --context $context apply -f -
if ($LASTEXITCODE -ne 0) { throw 'GPU resource configuration failed' }
kubectl --context $context wait --for=condition=Ready ec2nodeclass/gpu-training nodepool/gpu-training --timeout=180s
```

- 학습 Pod는 `nvidia.com/gpu`를 요청하고 `nvidia.com/gpu=true:NoSchedule` taint를 toleration으로 허용해야 합니다. GPU NodePool과 NVIDIA 플러그인은 스케줄링 담당자가 확정한 `devoops/gpu: "true"` 라벨을 사용합니다. Kueue EKS 오버레이도 이 기준으로 준비해야 합니다. 기존 노드에 대한 실제 적용은 별도 검증합니다.
- 첫 복구 테스트는 GPU 1장을 요청합니다. Kueue와 Ansible 사전 점검의 실험용 최소 용량은 실제 배치에 맞춰 설정합니다.
- 확인은 학습 Pod 제출 후 NodeClaim 생성, 노드 Ready 및 `nvidia.com/gpu` 할당을 보고 진행합니다. 테스트를 끝낸 뒤 GPU 자원 정리를 확인한 후 AWS 기반을 삭제합니다. EKS를 내리기 전에 NodePool을 제거하고 GPU NodeClaim과 EC2 종료를 확인합니다.

## 장애 감지·서비스 복구

ADR-11에 따라 개인 PC에서 `ansible/playbooks/recovery/`, `ansible/scripts/recovery/`를 필요할 때 수동 실행합니다. 전용 VM·상시 복구 timer는 사용하지 않습니다. 기본은 관찰 전용이며 설치/부트스트랩 site.yml과 분리합니다. [RECOVERY.md](ansible/RECOVERY.md)를 확인합니다.

## EKS별 설정

수동 비용 관리 ON/OFF 스크립트와 준비 조건은 [scripts/infra/README.md](scripts/infra/README.md) 참고. 스케줄링 배포 절차 연결 및 통합 검증 전에는 운영 ON/OFF 실행을 중단합니다.

온프레미스 기본 실행과 EKS별 실행을 분리했습니다. `ansible/environments/eks/`의 A/B/C 예시와 `playbooks/eks/`를 사용합니다. AWS 자원은 읽기 전용으로 점검하고 큐 설정은 gpu-k8s의 eks/<alias>가 관리합니다. [EKS 안내](ansible/EKS.md).
