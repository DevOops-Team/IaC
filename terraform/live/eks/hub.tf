# EKS를 만들고 지울 때 온프레 허브 등록도 함께 만들고 지운다 (GPU-142, GPU-126 계약).
# aws eks get-token은 Terraform과 같은 AWS_PROFILE을 쓴다 (run.sh 기본 devoops).
# 각 클러스터 안: multikueue-sa · argocd-manager · 토큰 Secret · training/ghcr-pull
# 온프레:        kueue-system/<eks>-kubeconfig · argocd/cluster-<eks> (devoops.site/gpu-worker)
# 노드그룹 대수만 바꿀 때는 아무것도 바뀌지 않는다 (ADR-25). 실행 방법: terraform/docs/EKS-HUB-REGISTRATION.md

provider "kubernetes" {
  alias          = "onprem"
  config_path    = pathexpand(var.hub_registration.onprem_kubeconfig)
  config_context = var.hub_registration.onprem_context
}

# provider는 for_each가 안 되므로 a · b · c를 하나씩 둔다 (config에 클러스터를 더하면 여기도 하나 더).
# 이번 토폴로지에 없는 클러스터는 접속하지 않는 자리표시 주소를 넣는다 (그 provider를 쓰는 리소스가 없음). 토큰은 SSO 관리자 역할로 받는다
# (modules/eks의 admin Access Entry).
# EKS API는 private이라 실행할 때 HTTPS_PROXY=socks5://127.0.0.1:1080 (ssh -D 1080 k8s-master1)로 넘긴다.
# provider의 proxy_url을 쓰면 클러스터를 처음 만들 때(엔드포인트가 아직 unknown) plan이
# "cannot load Kubernetes client config"로 실패한다. aws CLI(get-token)는 SOCKS를 못 쓰므로 그 프로세스만 끈다.
provider "kubernetes" {
  alias                  = "eks_a"
  host                   = try(module.eks["a"].cluster_endpoint, "https://eks-a.not-created.invalid")
  cluster_ca_certificate = try(base64decode(module.eks["a"].cluster_certificate_authority_data), null)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    env         = { HTTPS_PROXY = "", https_proxy = "", ALL_PROXY = "", all_proxy = "" }
    args        = ["eks", "get-token", "--cluster-name", "${local.name_prefix}-eks-a", "--region", local.region]
  }
}

provider "kubernetes" {
  alias                  = "eks_b"
  host                   = try(module.eks["b"].cluster_endpoint, "https://eks-b.not-created.invalid")
  cluster_ca_certificate = try(base64decode(module.eks["b"].cluster_certificate_authority_data), null)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    env         = { HTTPS_PROXY = "", https_proxy = "", ALL_PROXY = "", all_proxy = "" }
    args        = ["eks", "get-token", "--cluster-name", "${local.name_prefix}-eks-b", "--region", local.region]
  }
}

provider "kubernetes" {
  alias                  = "eks_c"
  host                   = try(module.eks["c"].cluster_endpoint, "https://eks-c.not-created.invalid")
  cluster_ca_certificate = try(base64decode(module.eks["c"].cluster_certificate_authority_data), null)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    env         = { HTTPS_PROXY = "", https_proxy = "", ALL_PROXY = "", all_proxy = "" }
    args        = ["eks", "get-token", "--cluster-name", "${local.name_prefix}-eks-c", "--region", local.region]
  }
}

module "hub_eks_a" {
  count              = contains(keys(local.clusters), "a") ? 1 : 0
  source             = "../../modules/eks-hub-registration"
  alias              = "eks-a"
  cluster_endpoint   = module.eks["a"].cluster_endpoint
  cluster_ca_data    = module.eks["a"].cluster_certificate_authority_data
  admin_access_ready = module.eks["a"].admin_access_policy_association_id

  providers = {
    kubernetes.eks    = kubernetes.eks_a
    kubernetes.onprem = kubernetes.onprem
  }
}

module "hub_eks_b" {
  count              = contains(keys(local.clusters), "b") ? 1 : 0
  source             = "../../modules/eks-hub-registration"
  alias              = "eks-b"
  cluster_endpoint   = module.eks["b"].cluster_endpoint
  cluster_ca_data    = module.eks["b"].cluster_certificate_authority_data
  admin_access_ready = module.eks["b"].admin_access_policy_association_id

  providers = {
    kubernetes.eks    = kubernetes.eks_b
    kubernetes.onprem = kubernetes.onprem
  }
}

module "hub_eks_c" {
  count              = contains(keys(local.clusters), "c") ? 1 : 0
  source             = "../../modules/eks-hub-registration"
  alias              = "eks-c"
  cluster_endpoint   = module.eks["c"].cluster_endpoint
  cluster_ca_data    = module.eks["c"].cluster_certificate_authority_data
  admin_access_ready = module.eks["c"].admin_access_policy_association_id

  providers = {
    kubernetes.eks    = kubernetes.eks_c
    kubernetes.onprem = kubernetes.onprem
  }
}

locals {
  hub_registrations = merge(
    { for m in module.hub_eks_a : "a" => m },
    { for m in module.hub_eks_b : "b" => m },
    { for m in module.hub_eks_c : "c" => m },
  )
}

output "hub_registration" {
  description = "On-prem Secrets and EKS ServiceAccounts that register each worker with the hub (no secret values)."
  value = {
    for alias, m in local.hub_registrations : alias => {
      onprem_secrets        = m.onprem_secrets
      argocd_cluster_labels = m.argocd_cluster_labels
      eks_service_accounts  = m.eks_service_accounts
    }
  }
}
