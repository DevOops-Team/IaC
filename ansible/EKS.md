# EKS A/B/C 전용 설정과 점검

AWS가 EKS·Karpenter GPU NodePool·네트워크·IAM을 생성한 뒤 이 파일들을 사용합니다. AWS 자원 생성·수정·삭제나 GPU 노드 SSH/systemd 복구는 수행하지 않습니다.

## 입력 파일

```text
environments/eks/
├─ eks-a.example.yml
├─ eks-b.example.yml
└─ eks-c.example.yml
```

각각 .local.yml로 복사하고 실제 값을 채웁니다. 로컬 파일은 Git 제외입니다.

- aws_region/aws_profile: 점검용 AWS CLI 자격증명. 빈 profile은 현재 실행 환경의 역할/기본 자격증명 사용.
- eks_cluster_name/eks_gpu_nodepool: AWS가 만든 실제 이름.
- eks_alias: Argo에 등록할 이름 eks-a/b/c.
- eks_context/eks_kubeconfig_file: 이 EKS에만 접속할 명시적 관리 context/파일.
- eks_cluster.kubeconfig_file: **별도 MultiKueue 전용** 내장 인증 kubeconfig. aws exec 등에 의존하지 않아야 함. playbooks/eks/multikueue-access.yml이 만들며, ansible/.cache/ 아래(Git 제외)에 둡니다.
- eks_cluster.multikueue_server(선택): 매니저가 이 EKS API에 닿는 주소가 관리용 kubeconfig의 server와 다를 때(VPN·사설 엔드포인트) 지정.
- GPU/system node selector: gpu-k8s/eks/<alias>/resources.yaml의 ResourceFlavor와 실제 노드 라벨에 맞춤.
- gitops_root_dir: 실행 환경에 내려받은 gpu-k8s/argocd/bootstrap/eks/<alias>의 절대 경로.
- manager_context/bootstrap_config_confirmed: 중앙 Argo에 root와 원격 Secret을 등록할 때만 필요.

기본 사전 조건은 GPU 노드 5개·GPU 총 5장 이상, 별도 시스템 노드 2개 이상입니다. 모든 선택 노드는 Ready·schedulable이어야 합니다. 선택한 GPU 노드가 지정 NodePool 및 Ready NodeClaim에 속하는지 확인합니다. NodePool limits는 실제 노드 수를 보장하지 않으며, 기본 5대 검사는 미리 용량을 확보한 실험 환경 기준입니다.

## EKS A만 점검

```bash
cd gpu-iac/ansible
cp environments/eks/eks-a.example.yml environments/eks/eks-a.local.yml
# 실제 값 입력 후 eks_config_confirmed=true
.venv/bin/ansible-playbook playbooks/eks/preflight.yml -e @environments/eks/eks-a.local.yml
```

읽기 전용으로 수행하는 검사:

1. AWS API의 EKS ACTIVE·Kubernetes 버전, kubeconfig endpoint 일치.
2. Karpenter CRD, 컨트롤러 Deployment rollout 상태.
3. GPU NodePool Ready·EC2NodeClass 참조와 Ready 상태.
4. 선택 GPU 노드의 karpenter.sh/nodepool 라벨과 해당 Ready NodeClaim 연결.
5. API readiness·선택적 UID, GPU 자원·별도 시스템 노드·Ready 상태.
6. JobSet/Kueue CRD, EKS Node Monitoring Agent add-on ACTIVE(기본 필수).

실제 Karpenter namespace·Deployment 이름은 eks_karpenter_namespace/eks_karpenter_deployment에 입력합니다. 모니터링을 Helm 등으로 관리한다면 eks_require_monitoring_addon=false로 AWS add-on 검사만 끄고 실제 에이전트를 별도 확인합니다.
Managed Node Group·그룹 desiredSize·그룹 Auto Repair 검사는 제거했습니다. 이 코드는 Karpenter나 NodePool을 설치/변경하지 않으며, Karpenter Node Repair 활성화 여부도 보장하지 않습니다. 장애 노드 교체 정책·Spot 중단 처리·예비 용량은 AWS 담당 설정으로 별도 검증해야 합니다.

## Registry·Argo root·MultiKueue credential을 따로 등록

```bash
# EKS A에만 GHCR Secret: EKS preflight를 먼저 실행하는 플레이북
.venv/bin/ansible-playbook playbooks/eks/seed-registry.yml -e @environments/eks/eks-a.local.yml

# 중앙 Argo에 EKS A root만 등록
.venv/bin/ansible-playbook playbooks/eks/register-root.yml -e @environments/eks/eks-a.local.yml

# EKS A에 MultiKueue 전용 ServiceAccount·토큰을 만들고 토큰 kubeconfig를 eks_cluster.kubeconfig_file에 작성
.venv/bin/ansible-playbook playbooks/eks/multikueue-access.yml -e @environments/eks/eks-a.local.yml

# EKS A의 전용 kubeconfig를 온프레미스 매니저 Secret으로 등록
.venv/bin/ansible-playbook playbooks/onprem/register-worker-credential.yml -e @environments/eks/eks-a.local.yml
```

multikueue-access.yml은 EKS의 kueue-system(없으면 생성, 이후 Kueue 설치가 이어받음)에 multikueue-sa ServiceAccount·최소 ClusterRole(Job·JobSet·Kueue Workload)·장기 토큰 Secret을 만들고, 토큰만 담은 kubeconfig를 0600으로 씁니다. EKS preflight를 거치지 않으므로 Kueue 설치 전에 실행할 수 있습니다. register-worker-credential.yml도 매니저에 kueue-system이 없으면 만든 뒤 Secret을 등록합니다.
토큰 교체: 해당 EKS에서 `kubectl -n kueue-system delete secret multikueue-sa` → multikueue-access.yml → register-worker-credential.yml 순서로 다시 실행합니다. 다른 잡 종류(PyTorchJob 등)를 디스패치하려면 roles/multikueue-remote/files/rbac.yaml에 권한을 먼저 추가합니다.

Registry에는 GHCR_USERNAME/GHCR_TOKEN이 필요합니다. EKS 등록 root는 별도로 Argo CLI 등에서 EKS를 eks-a 이름으로 등록한 뒤 sync합니다. 관리용 kubeconfig의 AWS exec 인증은 해당 실행 환경/profile에 맞게 준비합니다. AWS CLI 점검에 aws_profile을 줬다는 것만으로 다른 kubeconfig의 인증 profile이 자동 수정되지는 않습니다.
B/C는 각 local.yml로 따로 실행합니다. 하나의 명령에 세 EKS를 자동으로 묶지 않습니다.

## VPN·장애 경계

- 온프레미스 site.yml/Secret bootstrap은 더 이상 EKS API를 호출하지 않습니다.
- EKS preflight/registry는 EKS API와 AWS API에 접근 가능한 곳이면 실행 가능하며 온프레미스 VM inventory에 SSH하지 않습니다. AWS 내부 관리 환경에서 실행할 수도 있습니다.
- EKS root·MultiKueue Secret 등록은 중앙 Argo/매니저 API에 접근해야 합니다. 사설 API 경로가 VPN뿐이면 단절 중 중앙의 EKS 배포·조회가 제한됩니다.
- AWS 측 Karpenter와 EKS 내부 Kubernetes/JobSet의 동작은 온프레미스 서비스 복구기와 별개입니다. 복구기는 여전히 온프레미스 6대만 대상으로 합니다.
- 이 변경은 AWS 내부에 별도 Argo/복구 실행기/agent를 새로 설치하는 코드가 아닙니다.

공식 근거: [Karpenter NodePools](https://karpenter.sh/v1.15/concepts/nodepools/), [NodeClaims](https://karpenter.sh/v1.15/concepts/nodeclaims/).
