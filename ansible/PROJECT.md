# IaC 실행 순서

현재 상태는 코드 작성·로컬 검증이며 실제 VM/EKS/Cloudflare에는 적용하지 않았습니다.

## 1. 환경·VM 준비

```bash
cd gpu-iac/ansible
PYTHON_BIN=python3.12 ./scripts/setup-kubespray.sh
cp bootstrap.example.yml bootstrap.local.yml
```

이 명령들은 메인 서버의 Kubernetes 외부 Ansible 전용 Ubuntu VM(2 vCPU·RAM 2GB·디스크 20GB 계획)에서 실행합니다. Proxmox 호스트나 master1에 설치하지 않습니다. VM 생성 코드는 아직 없으므로 먼저 VM/네트워크·계정을 준비합니다. Python 3.12+, Git, kubectl, Helm/Argo CLI가 필요한 작업에 맞게 설치되어 있어야 합니다. VM 6대에 SSH·sudo·Python·swap off/cgroup v2를 준비합니다. VM 생성·IP·계정·공개키 초기 설정은 Terraform/VM 담당입니다.
SSH 계정은 VM마다 호스트 이름과 같습니다(master1~3, worker1~3). hosts.yaml에 호스트별 ansible_user로 적혀 있고, Kubespray가 sudo(--become)로 실행하므로 각 계정에 sudo 권한이 있어야 합니다. 설치는 6대에 SSH가 닿는 개인 로컬 우분투에서 실행해도 되며, 이 경우 admin.conf(inventory/onprem/artifacts/)는 그 머신에만 남습니다. 복구 실행기는 상시 켜진 VM이 필요합니다.
inventory/onprem/hosts.yaml의 실제 IP·SSH 계정·physical_host·리소스를 맞추고, ha.yml의 VIP·NIC와 Pod/Service CIDR 비중복을 확인한 다음 onprem_inventory_confirmed=true로 설정합니다.

```bash
.venv/bin/ansible-playbook playbooks/infra/configure-vms.yml --ask-become-pass
./scripts/run-cluster.sh --syntax-check
./scripts/run-cluster.sh --ask-become-pass
```

master1~3은 control-plane/etcd 전용이고 worker1~3에 앱을 배치합니다. kube-vip API 주소는 유지하고 서비스 VIP는 사용하지 않습니다. CoreDNS가 내부 Service DNS를 담당합니다.
관리 API-server는 kube_apiserver_feature_gates의 MutatingAdmissionPolicy=true, kube_api_runtime_config의 admissionregistration.k8s.io/v1beta1=true를 사용합니다. EKS 설정은 변경하지 않습니다.

## 2. Argo CD bootstrap

bootstrap.local.yml의 manager_context를 실제 kubeconfig context로 설정하고 bootstrap_config_confirmed=true로 바꿉니다. manager-preflight는 실제 6개 노드를 확인합니다.

```bash
.venv/bin/ansible-playbook playbooks/k8s/verify-manager-map.yml -e @bootstrap.local.yml
.venv/bin/ansible-playbook playbooks/bootstrap/install-argocd.yml -e @bootstrap.local.yml
```

공식 Argo CD v3.5.7 HA 매니페스트를 SHA256으로 고정해 내려받고 모든 Deployment/StatefulSet을 platform-worker=true 노드에 배치합니다. API/Repo/Application controller rollout을 확인합니다. 같은 Argo CD 설치 리소스를 GitOps에서 self-manage하지 않습니다. 향후 업그레이드는 해당 버전 절차를 검토하고 버전·checksum을 함께 바꿉니다.
Argo UI/API는 우선 `kubectl --context CONTEXT -n argocd port-forward svc/argocd-server 8080:443`으로 접속합니다.

## 3. GitHub·이미지·클러스터 등록

형제 gpu-k8s 폴더는 별도 저장소입니다. 아직 실제 GitHub URL이 없으므로 해당 저장소에서 configure.py로 URL·이미지·ACME 이메일을 설정하고 검증한 뒤 push합니다. CI는 gpu-k8s의 이미지 digest만 갱신하도록 연결합니다.
Argo CD에 비공개 repo 읽기 자격증명과 EKS 3개를 eks-a/eks-b/eks-c 이름으로 등록합니다. CLI 등록은 별도 관리 환경에서 수행하며 토큰·키는 Git에 넣지 않습니다. Argo CD cluster credential과 MultiKueue 전용 kubeconfig는 별도입니다.
bootstrap.local.yml의 gitops_repo_url과 gitops_root_dir(실행 머신의 gpu-k8s/argocd/bootstrap/onprem 절대 경로)를 맞춥니다. 부모 Git 저장소의 origin을 자동 사용하지 않습니다.

## 4. Secret·root 등록

실행 환경에 GHCR_USERNAME, GHCR_TOKEN, CLOUDFLARE_DNS_API_TOKEN을 공급합니다. Secret은 kubectl stdin으로만 전달하며 로그/렌더 파일에 쓰지 않습니다.

```bash
.venv/bin/ansible-playbook playbooks/bootstrap/seed-secrets.yml -e @bootstrap.local.yml
.venv/bin/ansible-playbook playbooks/bootstrap/register-root.yml -e @bootstrap.local.yml
```

EKS registry와 MultiKueue credential은 별도 playbooks/eks/seed-registry.yml 및 playbooks/onprem/register-worker-credential.yml에서 EKS별로 등록합니다. 해당 인증 파일은 CA·token 또는 내장 인증서가 있어야 하고 exec/auth-provider·외부 파일 의존성을 거부합니다. 유효기간·갱신은 별도 관리합니다.
부트스트랩은 Secret 등록을 위해 없는 namespace만 생성하며, 이후 namespace의 원하는 상태는 gpu-k8s가 관리합니다. 자동으로 Cloudflare token을 추정하거나 빈 값을 저장하지 않습니다.
site.yml은 MAP 확인 → Argo 설치 → Secret → root 등록을 묶습니다. 모든 실제 입력·접근 권한이 준비된 후에만 사용합니다. Cloudflare 외부 공개는 별도 단계입니다.

## 5. GitOps sync와 Cloudflare

gpu-k8s README의 최초 sync 순서에 따라 foundation → Traefik/cert-manager → 앱 → 웹 인증서 순서로 진행합니다. Kueue/JobSet과 MAP 정책·디스패처는 스케줄링 파트에서 설치하고 worker 큐·원격 Secret·매니저 연결 순서로 진행합니다.
frontend-tls가 production Ready이고 frontend endpoint가 준비된 후 Cloudflare account/zone과 환경변수 CLOUDFLARE_TUNNEL_API_TOKEN을 공급합니다.

```bash
.venv/bin/ansible-playbook playbooks/network/configure-cloudflare.yml -e @bootstrap.local.yml
```

이 플레이북은 외부 Tunnel·DNS·경로를 구성하고 cloudflare-system/cloudflared-token Secret을 저장합니다. cloudflared Deployment·PDB는 적용하거나 재시작하지 않습니다. 이후 Argo CD에서 gpu-cloudflared를 sync합니다. token 교체 후 실행 중인 커넥터는 운영 절차에 따라 rollout restart해야 합니다.

## 확인

```bash
.venv/bin/ansible-playbook playbooks/site.yml --syntax-check
```

VM 검사·설치·실제 장애 전환, 외부 DNS/Tunnel, API/IAM 권한과 학습 재개는 실제 환경에서 별도 검증해야 합니다. 이전 설정 파일이나 기존 리소스를 자동 삭제하지 않았습니다. 인계 중에는 기존 Ansible/Helm 배포를 다시 실행하지 않습니다.

## 장애 감지와 복구 실행기

기본 설치가 끝난 뒤 같은 메인 서버 전용 Ansible VM에 주기 실행기를 설치합니다. inventory/runner/hosts.yaml은 실행기 설치용이며 Kubernetes의 6개 노드 inventory와 분리합니다. site.yml에는 포함하지 않습니다. 진단·분류·회복 가능한 서비스 시작과 보류 조건은 [RECOVERY.md](RECOVERY.md)에 정리했습니다.

## 온프레미스/EKS 실행 분리

site.yml은 onprem/site.yml만 호출합니다. 온프레미스 bootstrap은 EKS API를 조회하거나 Secret을 쓰지 않습니다. EKS별 입력과 읽기 전용 점검·적용 진입점은 [EKS.md](EKS.md)를 따릅니다.
