data "aws_iam_roles" "sso_admin" {
  name_regex  = var.eks_admin_role_name_regex
  path_prefix = "/aws-reserved/sso.amazonaws.com/"
}

locals {
  # one(): 계정에 맞는 SSO 관리자 역할이 없거나 여러 개면 plan에서 바로 실패한다.
  eks_admin_role_arn    = one(data.aws_iam_roles.sso_admin.arns)
  checkpoint_bucket_arn = "arn:aws:s3:::${local.name_prefix}-ckpt-${local.account_id}-${local.region}"
  fencing_table_arn     = "arn:aws:dynamodb:${local.region}:${local.account_id}:table/${local.name_prefix}-fencing"

  gpu_instance_types = var.deployment_profile == "test" ? ["g4dn.xlarge"] : ["g4dn.xlarge", "g4dn.2xlarge"]
  eks_access_roles = {
    multikueue = {
      principal_arn     = "arn:aws:iam::${local.account_id}:role/${local.name_prefix}-onprem-multikueue"
      kubernetes_groups = ["devoops:multikueue"]
    }
    relocator = {
      principal_arn     = "arn:aws:iam::${local.account_id}:role/${local.name_prefix}-onprem-relocator"
      kubernetes_groups = ["devoops:relocator"]
    }
  }
}

module "eks_a" {
  source             = "../modules/eks"
  cluster_name       = "${local.name_prefix}-eks-a"
  kubernetes_version = "1.35"

  project_name          = var.project_name
  environment           = var.environment
  checkpoint_bucket_arn = local.checkpoint_bucket_arn
  fencing_table_arn     = local.fencing_table_arn
  onprem_access_roles   = local.eks_access_roles
  admin_role_arn        = local.eks_admin_role_arn

  vpc_id                  = local.vpc_id
  private_subnet_ids      = local.private_subnet_ids
  service_ipv4_cidr       = "10.100.0.0/16"
  onprem_cidr             = "172.30.0.0/24"
  cpu_instance_type       = "t3.large"
  cpu_node_az             = local.azs[0]
  cpu_disk_size           = 30
  gpu_instance_types      = local.gpu_instance_types
  gpu_training_node_count = var.deployment_profile == "full" ? 4 : 2
  gpu_spare_node_count    = var.deployment_profile == "full" ? 1 : 0
}

module "eks_b" {
  source             = "../modules/eks"
  cluster_name       = "${local.name_prefix}-eks-b"
  kubernetes_version = "1.35"

  project_name          = var.project_name
  environment           = var.environment
  checkpoint_bucket_arn = local.checkpoint_bucket_arn
  fencing_table_arn     = local.fencing_table_arn
  onprem_access_roles   = local.eks_access_roles
  admin_role_arn        = local.eks_admin_role_arn

  vpc_id                  = local.vpc_id
  private_subnet_ids      = local.private_subnet_ids
  service_ipv4_cidr       = "10.101.0.0/16"
  onprem_cidr             = "172.30.0.0/24"
  cpu_instance_type       = "t3.large"
  cpu_node_az             = local.azs[1]
  cpu_disk_size           = 30
  gpu_instance_types      = local.gpu_instance_types
  gpu_training_node_count = var.deployment_profile == "full" ? 4 : 0
  gpu_spare_node_count    = var.deployment_profile == "full" ? 1 : 0
}

module "eks_c" {
  count              = var.deployment_profile == "full" ? 1 : 0
  source             = "../modules/eks"
  cluster_name       = "${local.name_prefix}-eks-c"
  kubernetes_version = "1.35"

  project_name          = var.project_name
  environment           = var.environment
  checkpoint_bucket_arn = local.checkpoint_bucket_arn
  fencing_table_arn     = local.fencing_table_arn
  onprem_access_roles   = local.eks_access_roles
  admin_role_arn        = local.eks_admin_role_arn

  vpc_id                  = local.vpc_id
  private_subnet_ids      = local.private_subnet_ids
  service_ipv4_cidr       = "10.102.0.0/16"
  onprem_cidr             = "172.30.0.0/24"
  cpu_instance_type       = "t3.large"
  cpu_node_az             = local.azs[2]
  cpu_disk_size           = 30
  gpu_instance_types      = local.gpu_instance_types
  gpu_training_node_count = 4
  gpu_spare_node_count    = 1
}
