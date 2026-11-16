output "cluster_names" {
  description = "EKS clusters created by this root."
  value       = { for alias, cluster in local.eks_modules : alias => cluster.cluster_name }
}

output "trainer_role_arn" {
  description = "IAM role associated with training/trainer in eks-a."
  value       = module.eks_a.trainer_role_arn
}

output "trainer_pod_identity_association_id" {
  value = module.eks_a.trainer_pod_identity_association_id
}
