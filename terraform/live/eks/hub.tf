# EKS를 만들고 지울 때 온프레 허브(Argo CD · MultiKueue) 등록도 함께 만들고 지운다 (GPU-142).
# EKS 안: multikueue-sa · argocd-manager · 토큰 Secret · training/ghcr-pull
# 온프레:  kueue-system/<eks>-kubeconfig · argocd/cluster-<eks>
# 실행 방법: docs/EKS-HUB-REGISTRATION.md

provider "kubernetes" {
  alias          = "onprem"
  config_path    = pathexpand(var.hub_registration.onprem_kubeconfig)
  config_context = var.hub_registration.onprem_context
}

# provider는 for_each가 안 돼 a · b · c를 하나씩 둔다 (클러스터를 더하면 여기도 추가).
# 이번 토폴로지에 없는 클러스터는 접속하지 않는 자리표시 주소를 넣는다.
# EKS API가 private이라 HTTPS_PROXY(run.sh --proxy)로 접속한다. proxy_url은 첫 생성 때 plan이 실패해서 쓰지 않는다.
# aws eks get-token은 SOCKS를 못 써서 그 프로세스만 프록시를 끈다.
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
  description = "클러스터별 허브 등록 결과: 온프레 Secret · EKS ServiceAccount 이름 (비밀값 없음)."
  value = {
    for alias, m in local.hub_registrations : alias => {
      onprem_secrets        = m.onprem_secrets
      argocd_cluster_labels = m.argocd_cluster_labels
      eks_service_accounts  = m.eks_service_accounts
    }
  }
}
