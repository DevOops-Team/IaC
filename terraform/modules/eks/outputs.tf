output "trainer_role_arn" {
  description = "Pod Identity role for the training/trainer ServiceAccount."
  value       = aws_iam_role.trainer.arn
}

output "trainer_pod_identity_association_id" {
  value = aws_eks_pod_identity_association.trainer.association_id
}
