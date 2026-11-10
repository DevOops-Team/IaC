output "trainer_role_arn" {
  description = "Pod Identity role for the training/trainer ServiceAccount."
  value       = aws_iam_role.trainer.arn
}

output "trainer_pod_identity_association_id" {
  value = aws_eks_pod_identity_association.trainer.association_id
}

output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "cluster_arn" {
  value = aws_eks_cluster.this.arn
}

output "cluster_endpoint" {
  value = aws_eks_cluster.this.endpoint
}

output "cluster_primary_security_group_id" {
  value = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}
