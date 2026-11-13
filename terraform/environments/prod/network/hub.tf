# EKS를 만들고 지울 때 온프레 허브 등록도 함께 만들고 지운다 (GPU-142, GPU-126 계약).
# 각 클러스터 안: multikueue-sa · argocd-manager · 토큰 Secret · training/ghcr-pull
# 온프레:        kueue-system/<eks>-kubeconfig · argocd/cluster-<eks> (devoops.site/gpu-worker)
# 노드그룹 대수만 바꿀 때는 아무것도 바뀌지 않는다 (ADR-25). 실행 방법: terraform/EKS-HUB-REGISTRATION.md

provider "kubernetes" {
  alias          = "onprem"
  config_path    = pathexpand(var.hub_registration.onprem_kubeconfig)
  config_context = var.hub_registration.onprem_context
}

# provider는 for_each가 안 되므로 클러스터마다 하나씩 둔다. 토큰은 SSO 관리자 역할로 받는다
# (modules/eks의 admin Access Entry).
# EKS API는 private이라 실행할 때 HTTPS_PROXY=socks5://127.0.0.1:1080 (ssh -D 1080 k8s-master1)로 넘긴다.
# provider의 proxy_url을 쓰면 클러스터를 처음 만들 때(엔드포인트가 아직 unknown) plan이
# "cannot load Kubernetes client config"로 실패한다. aws CLI(get-token)는 SOCKS를 못 쓰므로 그 프로세스만 끈다.
provider "kubernetes" {
  alias                  = "eks_a"
  host                   = module.eks_a.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks_a.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    env         = { HTTPS_PROXY = "", https_proxy = "", ALL_PROXY = "", all_proxy = "" }
    args        = ["eks", "get-token", "--cluster-name", module.eks_a.cluster_name, "--region", "us-east-2", "--profile", var.hub_registration.aws_profile]
  }
}

provider "kubernetes" {
  alias                  = "eks_b"
  host                   = module.eks_b.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks_b.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    env         = { HTTPS_PROXY = "", https_proxy = "", ALL_PROXY = "", all_proxy = "" }
    args        = ["eks", "get-token", "--cluster-name", module.eks_b.cluster_name, "--region", "us-east-2", "--profile", var.hub_registration.aws_profile]
  }
}

# eks_c는 full 프로필에만 있다. 없을 때는 이 provider를 쓰는 리소스도 없지만, Terraform은 provider를
# 설정하므로 주소가 비어 있으면 실패한다. 접속하지 않는 자리표시 주소를 넣는다.
provider "kubernetes" {
  alias                  = "eks_c"
  host                   = try(module.eks_c[0].cluster_endpoint, "https://eks-c.not-created.invalid")
  cluster_ca_certificate = try(base64decode(module.eks_c[0].cluster_certificate_authority_data), null)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    env         = { HTTPS_PROXY = "", https_proxy = "", ALL_PROXY = "", all_proxy = "" }
    args        = ["eks", "get-token", "--cluster-name", "${local.name_prefix}-eks-c", "--region", "us-east-2", "--profile", var.hub_registration.aws_profile]
  }
}

module "hub_eks_a" {
  source             = "../../../modules/eks-hub-registration"
  alias              = "eks-a"
  cluster_endpoint   = module.eks_a.cluster_endpoint
  cluster_ca_data    = module.eks_a.cluster_certificate_authority_data
  admin_access_ready = module.eks_a.admin_access_policy_association_id

  providers = {
    kubernetes.eks    = kubernetes.eks_a
    kubernetes.onprem = kubernetes.onprem
  }
}

module "hub_eks_b" {
  source             = "../../../modules/eks-hub-registration"
  alias              = "eks-b"
  cluster_endpoint   = module.eks_b.cluster_endpoint
  cluster_ca_data    = module.eks_b.cluster_certificate_authority_data
  admin_access_ready = module.eks_b.admin_access_policy_association_id

  providers = {
    kubernetes.eks    = kubernetes.eks_b
    kubernetes.onprem = kubernetes.onprem
  }
}

module "hub_eks_c" {
  count              = length(module.eks_c)
  source             = "../../../modules/eks-hub-registration"
  alias              = "eks-c"
  cluster_endpoint   = module.eks_c[0].cluster_endpoint
  cluster_ca_data    = module.eks_c[0].cluster_certificate_authority_data
  admin_access_ready = module.eks_c[0].admin_access_policy_association_id

  providers = {
    kubernetes.eks    = kubernetes.eks_c
    kubernetes.onprem = kubernetes.onprem
  }
}

locals {
  hub_registrations = merge(
    { a = module.hub_eks_a, b = module.hub_eks_b },
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
