# EKS ↔ 온프레 허브 등록 (GPU-142)

`environments/prod/network`가 EKS를 만들 때 온프레 관리 클러스터(허브)에 그 EKS를 함께 등록하고, EKS를 지울 때 등록도 함께 지운다. 2026-11-12 GPU-127 E2E 때 스크립트로 직접 등록해 동작을 확인한 형식을 그대로 옮겼다. GPU-126 계약과 이름이 다른 부분(SA `multikueue-sa`)은 이 문서를 따른다.

## 무엇이 만들어지나

`modules/eks-hub-registration` 하나가 클러스터 하나를 맡는다. `hub.tf`가 eks-a · eks-b(항상), eks-c(full 프로필)마다 부른다.

| 위치 | 리소스 | 쓰는 곳 |
| --- | --- | --- |
| EKS | Namespace `kueue-system`, `training` | 아래 SA · Secret이 Argo CD보다 먼저 필요. 라벨 · 어노테이션은 Argo가 관리 |
| EKS | SA `kueue-system/multikueue-sa`, ClusterRole `multikueue-sa-role` + Binding, 토큰 Secret `kueue-system/multikueue-sa` | MultiKueue가 JobSet · Workload를 만들고 dispatcher가 용량을 읽음. Gitops `devoops-dispatcher-read`가 읽기 권한을 더함 |
| EKS | SA `kube-system/argocd-manager` + `cluster-admin`, 토큰 Secret `kube-system/argocd-manager-token` | 온프레 Argo CD가 Kueue · JobSet 차트(CRD · 웹훅)를 설치 |
| EKS | `training/ghcr-pull` | 비공개 trainer · checkpoint 이미지. 값은 온프레 `platform/ghcr-pull`을 그대로 복사 |
| 온프레 | `kueue-system/<eks>-kubeconfig` (키 `kubeconfig`) | Gitops `MultiKueueCluster <eks>` |
| 온프레 | `argocd/cluster-<eks>` (라벨 `argocd.argoproj.io/secret-type: cluster`, `devoops.site/gpu-worker: "true"`) | ApplicationSet `gpu-eks-scheduling`이 Kueue 0.20.4 · JobSet 0.13.0 · 워커 큐를 배포 (GPU-133) |

토큰은 만료 없는 `service-account-token` Secret이다(ADR-9). 등록이 끝나면 사람 손 없이 `gpu-eks-scheduling-<eks>`가 Synced/Healthy, `MultiKueueCluster <eks>`가 Connected=True가 된다.

노드그룹 대수만 바꿀 때(ADR-25)는 엔드포인트 · CA · 토큰이 그대로라 등록은 바뀌지 않는다.

## 실행 준비

EKS API는 private endpoint만 열려 있어 개인 PC에서 바로 닿지 않는다. 온프레 안으로 SOCKS5 프록시를 열고, plan · apply를 `HTTPS_PROXY=socks5://127.0.0.1:1080`으로 실행한다. kubernetes provider(EKS · 온프레)와 AWS provider가 모두 이 프록시를 지난다. 토큰을 받는 `aws eks get-token`은 SOCKS를 못 써서 provider가 그 프로세스에서만 프록시를 끈다. provider의 `proxy_url`은 쓰지 않는다: 클러스터를 처음 만들 때(엔드포인트가 아직 정해지지 않음) plan이 `cannot load Kubernetes client config`로 실패한다(11/12 재생성 시험에서 확인).

```sh
# 1) AWS SSO (EKS 관리자 Access Entry = AdministratorAccess 역할, 토큰은 aws eks get-token)
aws sso login --profile devoops

# 2) 온프레 kubeconfig: 172.30.0.120:6443, argocd · kueue-system Secret 쓰기 + platform/ghcr-pull 읽기
#    기본 경로 ~/.kube/devoops-onprem.yaml (hub_registration.onprem_kubeconfig로 바꿀 수 있음)
ssh k8s-master1 'cat ~/.kube/config' > ~/.kube/devoops-onprem.yaml && chmod 600 ~/.kube/devoops-onprem.yaml

# 3) EKS로 가는 SOCKS5 프록시 (apply 동안 열어 둠)
ssh -N -D 1080 k8s-master1 &

cd terraform/environments/prod/network
export HTTPS_PROXY=socks5://127.0.0.1:1080
terraform plan  -var-file=terraform.local.tfvars
terraform apply -var-file=terraform.local.tfvars
```

이 root를 plan하려면 위 세 가지가 항상 필요하다. 프록시가 없으면 EKS 쪽 리소스를 refresh하다 실패한다.

## 기존 eks-a · eks-b 넘겨받기 (1회)

11/12에 스크립트로 만든 리소스가 이미 있다. 처음 apply하기 전에 state로 가져온다. 가져오지 않으면 "already exists"로 실패한다. 토큰 Secret을 새로 만들면 토큰이 바뀌어 온프레 Secret도 다시 써지므로, 가져오는 쪽이 끊김이 없다.

```sh
for x in a b; do
  m="module.hub_eks_${x}"
  terraform import -var-file=terraform.local.tfvars "${m}.kubernetes_namespace_v1.this[\"kueue-system\"]" kueue-system
  terraform import -var-file=terraform.local.tfvars "${m}.kubernetes_namespace_v1.this[\"training\"]" training
  terraform import -var-file=terraform.local.tfvars "${m}.kubernetes_service_account_v1.multikueue" kueue-system/multikueue-sa
  terraform import -var-file=terraform.local.tfvars "${m}.kubernetes_cluster_role_v1.multikueue" multikueue-sa-role
  terraform import -var-file=terraform.local.tfvars "${m}.kubernetes_cluster_role_binding_v1.multikueue" multikueue-sa-crb
  terraform import -var-file=terraform.local.tfvars "${m}.kubernetes_secret_v1.multikueue_token" kueue-system/multikueue-sa
  terraform import -var-file=terraform.local.tfvars "${m}.kubernetes_service_account_v1.argocd_manager" kube-system/argocd-manager
  terraform import -var-file=terraform.local.tfvars "${m}.kubernetes_cluster_role_binding_v1.argocd_manager" argocd-manager
  terraform import -var-file=terraform.local.tfvars "${m}.kubernetes_secret_v1.argocd_manager_token" kube-system/argocd-manager-token
  terraform import -var-file=terraform.local.tfvars "${m}.kubernetes_secret_v1.ghcr_pull" training/ghcr-pull
  terraform import -var-file=terraform.local.tfvars "${m}.kubernetes_secret_v1.multikueue_kubeconfig" kueue-system/eks-${x}-kubeconfig
  terraform import -var-file=terraform.local.tfvars "${m}.kubernetes_secret_v1.argocd_cluster" argocd/cluster-eks-${x}
done
terraform plan -var-file=terraform.local.tfvars   # 등록 쪽 변경이 없거나 라벨 · 데이터 정리 정도여야 함
```

eks-a · eks-b의 `terraform import`는 provider가 엔드포인트를 알아야 하므로 두 클러스터가 state에 이미 있어야 한다(지금 그렇다).

## 지울 때

- `terraform destroy`나 프로필을 full → test로 내려 eks-c가 빠지면, 그 클러스터의 등록이 클러스터보다 먼저 지워진다(provider · 모듈 의존). 온프레 `kueue-system/<eks>-kubeconfig` · `argocd/cluster-<eks>`가 사라지면 ApplicationSet이 해당 Application을 지우고(리소스 보존 설정), `MultiKueueCluster <eks>`는 Inactive가 된다.
- 클러스터는 남기고 등록만 지우는 경우는 지원하지 않는다. 등록이 `kueue-system` · `training` 네임스페이스를 갖고 있어서 Argo가 설치한 Kueue도 같이 지워진다.

## 보안

- 두 토큰과 kubeconfig가 state에 남는다. state 버킷은 SSE-S3 · 버전 관리 · HTTPS 전용이다(`STATE-BACKEND.md`). 로컬 plan 파일도 비밀값을 담으니 공유하지 않는다.
- 온프레 쪽은 지금 관리자 kubeconfig를 쓴다. `argocd` · `kueue-system` Secret 쓰기와 `platform/ghcr-pull` 읽기만 되는 전용 계정으로 바꾸는 것은 후속 작업이다.

## 이 레포 밖에서 함께 필요한 것

- EKS → 온프레 Kafka(172.30.0.40-42:9092): pfSense **IPsec** 탭 인바운드 규칙(TCP, src `172.28.0.0/16`). 11/12 수동 적용했고 `ansible/roles/pfsense-edge`에는 아직 없다.
- relocator kubeconfig(`kueue-system/<eks>-relocator-kubeconfig`)는 이 모듈 범위 밖이다(GPU-99 결정 대기).

## 검증

`terraform test`(mock provider, 네트워크 · 클라우드 호출 없음): `tests/hub-registration.tftest.hcl`이 test 프로필은 a · b만, full은 a · b · c를 등록하는지, Secret 이름 · Argo 라벨 · SA 이름이 Gitops 계약과 같은지 확인한다.
