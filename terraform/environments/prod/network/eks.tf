data "aws_iam_role" "eks_admin" {
  name = "AWSReservedSSO_AdministratorAccess_131648b14fa0739c"
}

locals {
  gpu_instance_types = var.deployment_profile == "test" ? ["g4dn.xlarge"] : ["g4dn.xlarge", "g4dn.2xlarge"]
  eks_access_roles = {
    multikueue = {
      principal_arn     = "arn:aws:iam::354363695096:role/${local.name_prefix}-onprem-multikueue"
      kubernetes_groups = ["devoops:multikueue"]
    }
    relocator = {
      principal_arn     = "arn:aws:iam::354363695096:role/${local.name_prefix}-onprem-relocator"
      kubernetes_groups = ["devoops:relocator"]
    }
  }
}

# Preserve the deployed eks_a module address; only B/C are new clusters.
module "eks_a" {
  source             = "../../../modules/eks"
  cluster_name       = "${local.name_prefix}-eks-a"
  kubernetes_version = "1.35"

  project_name          = var.project_name
  environment           = var.environment
  checkpoint_bucket_arn = "arn:aws:s3:::${local.name_prefix}-ckpt-354363695096-us-east-2"
  fencing_table_arn     = "arn:aws:dynamodb:us-east-2:354363695096:table/${local.name_prefix}-fencing"
  onprem_access_roles   = local.eks_access_roles
  admin_role_arn        = data.aws_iam_role.eks_admin.arn

  vpc_id                  = aws_vpc.this.id
  private_subnet_ids      = { for az, subnet in aws_subnet.private : az => subnet.id }
  service_ipv4_cidr       = "10.100.0.0/16"
  onprem_cidr             = "172.30.0.0/24"
  cpu_instance_type       = "t3.large"
  cpu_node_az             = "us-east-2a"
  cpu_disk_size           = 30
  gpu_instance_types      = local.gpu_instance_types
  gpu_training_node_count = var.deployment_profile == "full" ? 4 : 2
  gpu_spare_node_count    = var.deployment_profile == "full" ? 1 : 0

  depends_on = [
    aws_route.public_internet,
    aws_route.private_internet,
    aws_route_table_association.public,
    aws_route_table_association.private,
  ]
}

module "eks_b" {
  source             = "../../../modules/eks"
  cluster_name       = "${local.name_prefix}-eks-b"
  kubernetes_version = "1.35"

  project_name          = var.project_name
  environment           = var.environment
  checkpoint_bucket_arn = "arn:aws:s3:::${local.name_prefix}-ckpt-354363695096-us-east-2"
  fencing_table_arn     = "arn:aws:dynamodb:us-east-2:354363695096:table/${local.name_prefix}-fencing"
  onprem_access_roles   = local.eks_access_roles
  admin_role_arn        = data.aws_iam_role.eks_admin.arn

  vpc_id                  = aws_vpc.this.id
  private_subnet_ids      = { for az, subnet in aws_subnet.private : az => subnet.id }
  service_ipv4_cidr       = "10.101.0.0/16"
  onprem_cidr             = "172.30.0.0/24"
  cpu_instance_type       = "t3.large"
  cpu_node_az             = "us-east-2b"
  cpu_disk_size           = 30
  gpu_instance_types      = local.gpu_instance_types
  gpu_training_node_count = var.deployment_profile == "full" ? 4 : 0
  gpu_spare_node_count    = var.deployment_profile == "full" ? 1 : 0

  depends_on = [
    aws_route.public_internet,
    aws_route.private_internet,
    aws_route_table_association.public,
    aws_route_table_association.private,
  ]
}

module "eks_c" {
  count              = var.deployment_profile == "full" ? 1 : 0
  source             = "../../../modules/eks"
  cluster_name       = "${local.name_prefix}-eks-c"
  kubernetes_version = "1.35"

  project_name          = var.project_name
  environment           = var.environment
  checkpoint_bucket_arn = "arn:aws:s3:::${local.name_prefix}-ckpt-354363695096-us-east-2"
  fencing_table_arn     = "arn:aws:dynamodb:us-east-2:354363695096:table/${local.name_prefix}-fencing"
  onprem_access_roles   = local.eks_access_roles
  admin_role_arn        = data.aws_iam_role.eks_admin.arn

  vpc_id                  = aws_vpc.this.id
  private_subnet_ids      = { for az, subnet in aws_subnet.private : az => subnet.id }
  service_ipv4_cidr       = "10.102.0.0/16"
  onprem_cidr             = "172.30.0.0/24"
  cpu_instance_type       = "t3.large"
  cpu_node_az             = "us-east-2c"
  cpu_disk_size           = 30
  gpu_instance_types      = local.gpu_instance_types
  gpu_training_node_count = 4
  gpu_spare_node_count    = 1

  depends_on = [
    aws_route.public_internet,
    aws_route.private_internet,
    aws_route_table_association.public,
    aws_route_table_association.private,
  ]
}
