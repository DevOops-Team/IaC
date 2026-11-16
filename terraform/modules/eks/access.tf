# SSO 관리자 역할: 클러스터 관리자 (Terraform · 허브 등록이 이 권한으로 API를 호출)
resource "aws_eks_access_entry" "admin" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = var.admin_role_arn
  type          = "STANDARD"
}

# 온프레 워크로드 역할(multikueue · relocator)의 인증만 한다. 권한(RBAC)은 Gitops가 그룹 단위로 준다.
resource "aws_eks_access_entry" "onprem" {
  for_each          = var.onprem_access_roles
  cluster_name      = aws_eks_cluster.this.name
  principal_arn     = each.value.principal_arn
  kubernetes_groups = each.value.kubernetes_groups
  type              = "STANDARD"
}

resource "aws_eks_access_policy_association" "admin" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_eks_access_entry.admin.principal_arn

  policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}
