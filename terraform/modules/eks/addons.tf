# Pod에 IAM 인증 정보를 제공하는 에이전트
resource "aws_eks_addon" "pod_identity_agent" {
  cluster_name  = aws_eks_cluster.this.name
  addon_name    = "eks-pod-identity-agent"
  addon_version = var.addon_versions["eks-pod-identity-agent"]
}

# Pod IP와 노드 네트워크 구성
resource "aws_eks_addon" "vpc_cni" {
  cluster_name  = aws_eks_cluster.this.name
  addon_name    = "vpc-cni"
  addon_version = var.addon_versions["vpc-cni"]

  pod_identity_association {
    service_account = "aws-node"
    role_arn        = aws_iam_role.vpc_cni.arn
  }

  depends_on = [
    aws_iam_role_policy_attachment.vpc_cni,
    aws_eks_addon.pod_identity_agent,
  ]
}

# Kubernetes Service 트래픽 처리
resource "aws_eks_addon" "kube_proxy" {
  cluster_name  = aws_eks_cluster.this.name
  addon_name    = "kube-proxy"
  addon_version = var.addon_versions["kube-proxy"]
}

# 클러스터 내부 DNS — 실행할 노드가 준비된 다음 설치
resource "aws_eks_addon" "coredns" {
  cluster_name  = aws_eks_cluster.this.name
  addon_name    = "coredns"
  addon_version = var.addon_versions["coredns"]

  depends_on = [
    aws_eks_node_group.cpu
  ]
}