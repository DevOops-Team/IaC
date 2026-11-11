locals {
  gpu_node_groups = {
    for role, count in {
      training = var.gpu_training_node_count
      spare    = var.gpu_spare_node_count
    } : role => count if count > 0
  }
}

# Node instance roles cannot access application S3/DynamoDB data. Pods use their
# existing trainer Pod Identity role; aws-node uses its separate CNI role.
resource "aws_iam_role" "gpu_node" {
  name = "${var.cluster_name}-gpu-node-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "gpu_node" {
  for_each = toset([
    "AmazonEKSWorkerNodePolicy",
    "AmazonEC2ContainerRegistryPullOnly",
  ])
  role       = aws_iam_role.gpu_node.name
  policy_arn = "arn:aws:iam::aws:policy/${each.value}"
}

resource "aws_launch_template" "gpu" {
  for_each    = local.gpu_node_groups
  name_prefix = "${var.cluster_name}-gpu-${each.key}-"

  # Do not specify image_id or instance_type here. EKS selects its pinned NVIDIA
  # AMI and the Spot ASG selects from the node group's two eligible types.
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = var.gpu_disk_size
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
      Name        = "${var.cluster_name}-gpu-${each.key}"
      EKSCluster  = var.cluster_name
      NodeRole    = each.key
      ManagedBy   = "Terraform"
      Project     = var.project_name
      Environment = var.environment
    }
  }
}

resource "aws_eks_node_group" "gpu" {
  for_each = local.gpu_node_groups

  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.cluster_name}-gpu-${each.key}"
  node_role_arn   = aws_iam_role.gpu_node.arn
  # CPU and GPU workers for this cluster stay in the cluster's assigned AZ;
  # its control-plane ENIs still use private subnets across multiple AZs.
  subnet_ids      = [var.private_subnet_ids[var.cpu_node_az]]
  capacity_type   = "SPOT"
  instance_types  = var.gpu_instance_types
  ami_type        = "AL2023_x86_64_NVIDIA"
  version         = var.kubernetes_version
  release_version = var.gpu_ami_release_version

  scaling_config {
    min_size     = each.value
    desired_size = each.value
    max_size     = each.value
  }

  launch_template {
    id      = aws_launch_template.gpu[each.key].id
    version = tostring(aws_launch_template.gpu[each.key].latest_version)
  }

  labels = merge({
    "devoops/gpu"       = "true"
    "devoops/node-role" = each.key
  }, each.key == "spare" ? { "devoops/spare" = "true" } : {})

  taint {
    key    = "nvidia.com/gpu"
    value  = "true"
    effect = "NO_SCHEDULE"
  }

  dynamic "taint" {
    for_each = each.key == "spare" ? [true] : []
    content {
      key    = "devoops/spare"
      value  = "true"
      effect = "NO_SCHEDULE"
    }
  }

  # GPU version updates terminate before replacement to avoid an update surge.
  # Spot rebalancing/failures may still temporarily change healthy capacity.
  update_config {
    max_unavailable = 1
    update_strategy = "MINIMAL"
  }

  depends_on = [
    aws_iam_role_policy_attachment.gpu_node,
    aws_eks_addon.pod_identity_agent,
    aws_eks_addon.vpc_cni,
    aws_eks_addon.kube_proxy,
  ]

  tags = {
    Name     = "${var.cluster_name}-gpu-${each.key}"
    NodeRole = each.key
  }
}
