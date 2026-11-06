# CPU 노드의 디스크·메타데이터 설정
resource "aws_launch_template" "cpu" {
  name_prefix = "${var.cluster_name}-cpu-"

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = var.cpu_disk_size
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name        = "${var.cluster_name}-cpu"
      EKSCluster  = var.cluster_name
      ManagedBy   = "Terraform"
      Project     = var.project_name
      Environment = var.environment
    }
  }
}

# 시스템 Pod를 실행할 On-Demand CPU 노드 그룹
resource "aws_eks_node_group" "cpu" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.cluster_name}-cpu"
  node_role_arn   = aws_iam_role.cpu_node.arn

  subnet_ids = [
    var.private_subnet_ids[var.cpu_node_az]
  ]

  capacity_type  = "ON_DEMAND"
  instance_types = [var.cpu_instance_type]
  ami_type       = "AL2023_x86_64_STANDARD"
  version        = var.kubernetes_version

  scaling_config {
    min_size     = 1
    desired_size = 1
    max_size     = 1
  }

  launch_template {
    id      = aws_launch_template.cpu.id
    version = tostring(aws_launch_template.cpu.latest_version)
  }

  labels = {
    workload = "system"
  }

  update_config {
    max_unavailable = 1
  }

  depends_on = [
    aws_iam_role_policy_attachment.cpu_node,
    aws_eks_addon.pod_identity_agent,
    aws_eks_addon.vpc_cni,
    aws_eks_addon.kube_proxy,
  ]

  tags = {
    Name = "${var.cluster_name}-cpu"
  }
}
