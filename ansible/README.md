# IaC Ansible

ADR-11에 따라 개인 PC에서 필요할 때 수동으로 VM 6대 공통 준비·Kubespray Kubernetes HA·API VIP·CoreDNS·MAP와 Argo CD bootstrap을 관리합니다. 전용 Ansible VM과 상시 점검 timer는 사용하지 않습니다.
앱·클러스터 내 일반 리소스는 gpu-k8s로 이동했고 기존 apps/edge/render 플레이북 및 리소스 적용 role은 제거했습니다.

| 영역 | 플레이북 |
|---|---|
| VM 검사·준비 | infra/preflight.yml, infra/configure-vms.yml |
| Kubernetes 설치 | scripts/run-cluster.sh → 고정 Kubespray |
| MAP API 확인 | k8s/verify-manager-map.yml |
| Argo CD HA 최초 설치/명시적 업그레이드 | bootstrap/install-argocd.yml |
| 비밀값 등록·갱신 | bootstrap/seed-secrets.yml |
| GitOps project/root 최초 등록 | bootstrap/register-root.yml |
| 외부 Cloudflare 계정 리소스 | network/configure-cloudflare.yml |
| 설치 후 부트스트랩 묶음 | site.yml |

자세한 명령은 PROJECT.md, Cloudflare 인계는 EDGE.md를 확인합니다. bootstrap.example.yml을 bootstrap.local.yml로 복사해 실제 값으로 바꿉니다. 기존 project.local.yml/edge.local.yml이 있다면 자동 삭제하지 않았지만 새 실행 경로에서는 읽지 않습니다.

## 장애 대응

`playbooks/recovery/`는 개인 PC에서 수동으로 수행하는 진단·한 노드 서비스 복구용입니다. 기존 install-runner.yml은 ADR-11 안내와 함께 종료하며 timer를 설치하지 않습니다. `scripts/recovery/watcher.py`가 장애를 분류하고 명시적 설정을 켠 경우만 호출합니다. 기본 관찰 전용이며 [RECOVERY.md](RECOVERY.md)를 따릅니다.

## 온프레미스/EKS 실행 분리

site.yml은 onprem/site.yml만 호출합니다. 온프레미스 bootstrap은 EKS API를 조회하거나 Secret을 쓰지 않습니다. EKS별 입력과 읽기 전용 점검·적용 진입점은 [EKS.md](EKS.md)를 따릅니다.
