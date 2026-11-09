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

## 장애 감지·서비스 복구

ADR-11에 따라 개인 PC에서 `ansible/playbooks/recovery/`, `ansible/scripts/recovery/`를 필요할 때 수동 실행합니다. 전용 VM·상시 복구 timer는 사용하지 않습니다. 기본은 관찰 전용이며 설치/부트스트랩 site.yml과 분리합니다. [RECOVERY.md](ansible/RECOVERY.md)를 확인합니다.

## EKS별 설정

온프레미스 기본 실행과 EKS별 실행을 분리했습니다. `ansible/environments/eks/`의 A/B/C 예시와 `playbooks/eks/`를 사용합니다. AWS 자원은 읽기 전용으로 점검하고 큐 설정은 gpu-k8s의 eks/<alias>가 관리합니다. [EKS 안내](ansible/EKS.md).
