# IaC 실행 순서

현재 상태는 코드 작성·로컬 검증이며 실제 VM/EKS/Cloudflare에는 적용하지 않았습니다.

## 1. 환경·VM 준비

```bash
cd gpu-iac/ansible
PYTHON_BIN=python3.12 ./scripts/setup-kubespray.sh
cp bootstrap.example.yml bootstrap.local.yml
```

이 명령들은 ADR-11에 따라 Kubernetes 밖의 개인 PC에서 필요할 때 수동 실행합니다. 전용 VM을 만들거나 Proxmox 호스트·master1에 Ansible 실행기를 설치하지 않습니다. 개인 PC에는 Python 3.12+, Git, kubectl과 작업에 필요한 CLI를 준비합니다. macOS/Linux의 SSH 실행 환경을 사용하고 Windows는 WSL/Linux 환경을 준비합니다. VM 6대의 SSH·sudo·Python 등 대상 준비는 VM 담당과 확인합니다.
SSH 계정은 VM 이름(master1~3, worker1~3)이며 hosts.yaml의 ansible_user에 기록합니다. kubeconfig·SSH 키는 개인 PC의 비공개 경로에 보관합니다. admin.conf(inventory/onprem/artifacts/)는 실행한 PC에만 생기므로 접근을 제한합니다. 개인 PC를 Kubernetes inventory에 추가하지 않습니다.
inventory/onprem/hosts.yaml의 실제 IP·SSH 계정·physical_host·리소스를 맞추고, ha.yml의 VIP·NIC와 Pod/Service CIDR 비중복을 확인한 다음 onprem_inventory_confirmed=true로 설정합니다.

배포 계정이 sudo 비밀번호를 요구하면 --ask-become-pass를 붙입니다. run-cluster.sh는 비밀번호를 한 번만 묻고 네 플레이북에 함께 사용합니다.

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

형제 gpu-k8s 폴더는 별도 저장소(https://github.com/DevOops-Team/K8s.git)입니다. 해당 저장소에서 configure.py로 이미지·ACME 이메일 등 실제 입력을 설정하고 검증한 뒤 push합니다. CI는 gpu-k8s의 이미지 digest만 갱신하도록 연결합니다.
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
frontend-tls가 production Ready이고 frontend endpoint가 준비된 후 공인 IP → pfSense → Traefik HTTPS를 외부에서 검증합니다. Cloudflare zone·edge_public_ip와 CLOUDFLARE_DNS_API_TOKEN을 공급하고 edge_dns_confirmed를 true로 설정합니다.

```bash
.venv/bin/ansible-playbook playbooks/network/configure-cloudflare.yml -e @bootstrap.local.yml
```

이 플레이북은 DNS-only A/AAAA 레코드만 구성합니다. Tunnel·커넥터 토큰은 만들지 않습니다. 기존 DNS 변경은 레코드 ID와 현재 내용을 명시해야 합니다. 전환·정리 순서는 [EDGE.md](EDGE.md)를 따릅니다.

## 확인

```bash
.venv/bin/ansible-playbook playbooks/site.yml --syntax-check
```

VM 검사·설치·실제 장애 전환, 외부 DNS·pfSense 전달, API/IAM 권한과 학습 재개는 실제 환경에서 별도 검증해야 합니다. 이전 설정 파일이나 기존 리소스를 자동 삭제하지 않았습니다. 인계 중에는 기존 Ansible/Helm 배포를 다시 실행하지 않습니다.

## 장애 감지와 복구 실행기

개인 PC에서 읽기 전용 진단을 수동 실행하고 결과를 검토한 뒤 필요할 때만 제한된 서비스 복구를 호출합니다. 전용 VM·runner inventory·systemd 복구 timer 설치 구성은 제거했습니다. 기존 install-runner.yml은 설치하지 않고 ADR-11 안내와 함께 종료합니다. PC가 꺼져 있거나 명령을 실행하지 않으면 Ansible 점검·복구는 동작하지 않습니다. 진단·분류·회복 가능한 서비스 시작과 보류 조건은 [RECOVERY.md](RECOVERY.md)에 정리했습니다.

## 온프레미스/EKS 실행 분리

site.yml은 onprem/site.yml만 호출합니다. 온프레미스 bootstrap은 EKS API를 조회하거나 Secret을 쓰지 않습니다. EKS별 입력과 읽기 전용 점검·적용 진입점은 [EKS.md](EKS.md)를 따릅니다.


외부 진입점의 pfSense TCP443 포트 전달은 `playbooks/network/configure-pfsense-edge.yml`로 별도 적용합니다. 설치·연결 입력·단일 워커 진입점의 제한은 [EDGE.md](EDGE.md)를 확인합니다.
