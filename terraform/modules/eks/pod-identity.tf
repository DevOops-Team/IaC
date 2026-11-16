resource "aws_eks_pod_identity_association" "trainer" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = "training"
  service_account = "trainer"
  role_arn        = module.trainer_role.arn

  depends_on = [
    module.trainer_role,
    aws_eks_addon.pod_identity_agent,
  ]
}
