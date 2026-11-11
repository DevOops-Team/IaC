output "vpc_id" {
  description = "ID of the project VPC."
  value       = aws_vpc.this.id
}

output "trainer_role_arn" {
  description = "IAM role associated with training/trainer in eks-a."
  value       = module.eks_a.trainer_role_arn
}

output "trainer_pod_identity_association_id" {
  value = module.eks_a.trainer_pod_identity_association_id
}

output "public_subnet_ids" {
  description = "Public subnet IDs keyed by Availability Zone."
  value = {
    for az, subnet in aws_subnet.public : az => subnet.id
  }
}

output "private_subnet_ids" {
  description = "Private subnet IDs keyed by Availability Zone."
  value = {
    for az, subnet in aws_subnet.private : az => subnet.id
  }
}

output "lifecycle" {
  description = "Current AWS identifiers used by the on-premises lifecycle runner."
  value = {
    vpn_connection_id = aws_vpn_connection.this.id
    cluster_name      = module.eks_a.cluster_name
  }
}
