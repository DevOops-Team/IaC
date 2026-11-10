data "aws_iam_role" "eks_admin" {
  name = "AWSReservedSSO_AdministratorAccess_131648b14fa0739c"
}

module "eks_a" {
  source = "../../../modules/eks"

  cluster_name       = "${local.name_prefix}-eks-a"
  kubernetes_version = "1.35"

  project_name = var.project_name
  environment  = var.environment

  # These resources belong to prod/data; do not require applied remote state to plan.
  checkpoint_bucket_arn = "arn:aws:s3:::${local.name_prefix}-ckpt-354363695096-us-east-2"
  fencing_table_arn     = "arn:aws:dynamodb:us-east-2:354363695096:table/${local.name_prefix}-fencing"

  # prod/identity must be created first when apply is eventually authorized.
  onprem_access_roles = {
    multikueue = {
      principal_arn     = "arn:aws:iam::354363695096:role/${local.name_prefix}-onprem-multikueue"
      kubernetes_groups = ["devoops:multikueue"]
    }
    relocator = {
      principal_arn     = "arn:aws:iam::354363695096:role/${local.name_prefix}-onprem-relocator"
      kubernetes_groups = ["devoops:relocator"]
    }
  }

  vpc_id = aws_vpc.this.id

  private_subnet_ids = {
    for az, subnet in aws_subnet.private : az => subnet.id
  }

  service_ipv4_cidr = "10.100.0.0/16"
  onprem_cidr       = "172.30.0.0/24"

  admin_role_arn = data.aws_iam_role.eks_admin.arn

  cpu_instance_type = "t3.large"
  cpu_node_az       = "us-east-2a"
  cpu_disk_size     = 30

  depends_on = [
    aws_route.public_internet,
    aws_route.private_internet,
    aws_route_table_association.public,
    aws_route_table_association.private,
  ]
}
