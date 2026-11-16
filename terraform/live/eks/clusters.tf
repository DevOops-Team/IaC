# config eks.topologies[<topology>]의 클러스터마다 EKS 하나 (modules/eks).
data "aws_iam_roles" "sso_admin" {
  name_regex  = var.eks_admin_role_name_regex
  path_prefix = "/aws-reserved/sso.amazonaws.com/"
}

locals {
  topology_name = coalesce(var.deployment_profile, local.cfg.eks.topology)
  topology      = local.cfg.eks.topologies[local.topology_name]
  azs           = sort(keys(try(local.network.private_subnet_ids, {})))

  # 클러스터 키 => config clusters (service_cidr · az_index) + 이 토폴로지의 GPU 수량
  clusters = {
    for alias in local.topology.clusters : alias => merge(local.cfg.eks.clusters[alias], local.topology.gpu[alias])
  }

  # one(): 계정에 맞는 SSO 관리자 역할이 없거나 여러 개면 plan에서 바로 실패한다
  eks_admin_role_arn = one(data.aws_iam_roles.sso_admin.arns)
}

module "eks" {
  source   = "../../modules/eks"
  for_each = local.clusters

  cluster_name       = "${local.name_prefix}-eks-${each.key}"
  kubernetes_version = local.cfg.eks.kubernetes_version
  project_name       = local.cfg.project
  environment        = local.cfg.environment

  checkpoint_bucket_arn = local.base.checkpoint_bucket.arn
  fencing_table_arn     = local.base.fencing_table.arn
  admin_role_arn        = local.eks_admin_role_arn
  onprem_access_roles = {
    multikueue = { principal_arn = local.base.onprem_role_arns["multikueue"], kubernetes_groups = ["devoops:multikueue"] }
    relocator  = { principal_arn = local.base.onprem_role_arns["relocator"], kubernetes_groups = ["devoops:relocator"] }
  }

  vpc_id             = try(local.network.vpc_id, null)
  private_subnet_ids = try(local.network.private_subnet_ids, {})
  service_ipv4_cidr  = each.value.service_cidr
  onprem_cidr        = local.cfg.eks.onprem_cidr
  cpu_instance_type  = local.cfg.eks.cpu.instance_type
  cpu_disk_size      = local.cfg.eks.cpu.disk_size
  cpu_node_az        = try(local.azs[each.value.az_index], null)

  gpu_instance_types      = local.topology.gpu_instance_types
  gpu_training_node_count = each.value.training
  gpu_spare_node_count    = each.value.spare

  depends_on = [terraform_data.require_network]
}
