# 온프레에서 EKS API에 접근할 때 사용할 추가 보안 그룹
resource "aws_security_group" "api_access" {
  name        = "${var.cluster_name}-api-access"
  description = "Allow EKS private API access from on-premises."
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.cluster_name}-api-access"
  }
}

resource "aws_vpc_security_group_ingress_rule" "onprem_api" {
  security_group_id = aws_security_group.api_access.id
  description       = "HTTPS from on-premises over VPN."

  cidr_ipv4   = var.onprem_cidr
  ip_protocol = "tcp"
  from_port   = 443
  to_port     = 443
}

resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  # 기본 애드온은 다음 단계에서 관리형 애드온으로 명시적으로 구성
  bootstrap_self_managed_addons = false

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = false
  }

  kubernetes_network_config {
    ip_family         = "ipv4"
    service_ipv4_cidr = var.service_ipv4_cidr
  }

  vpc_config {
    subnet_ids = values(var.private_subnet_ids)

    endpoint_private_access = true
    endpoint_public_access  = false

    security_group_ids = [aws_security_group.api_access.id]
  }

  depends_on = [
    aws_iam_role_policy_attachment.cluster
  ]

  tags = {
    Name = var.cluster_name
  }
}