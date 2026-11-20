# GPU 노드그룹: 학습(training) · 예비(spare), 수량 0이면 그룹을 만들지 않는다. 모두 Spot, 최소=희망=최대 고정.
locals {
  gpu_node_groups = {
    for role, count in {
      training = var.gpu_training_node_count
      spare    = var.gpu_spare_node_count
    } : role => count if count > 0
  }

  # 관리형 노드그룹 launch template의 user data는 MIME multipart여야 한다 (AL2023 nodeadm).
  gpu_user_data = <<-EOT
    MIME-Version: 1.0
    Content-Type: multipart/mixed; boundary="BOUNDARY"

    --BOUNDARY
    Content-Type: application/node.eks.aws

    ---
    apiVersion: node.eks.aws/v1alpha1
    kind: NodeConfig
    spec:
      instance:
        localStorage:
          strategy: RAID0

    --BOUNDARY--
  EOT
}

resource "aws_launch_template" "gpu" {
  for_each    = local.gpu_node_groups
  name_prefix = "${var.cluster_name}-gpu-${each.key}-"

  # image_id · instance_type은 비운다: AMI는 노드그룹의 고정 NVIDIA 릴리스, 유형은 Spot이 허용 목록에서 고른다.
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = var.gpu_disk_size
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  # 로컬 NVMe(인스턴스 스토어)를 RAID0으로 묶어 /mnt/k8s-disks에 올리고 containerd · 파드 로그 등을 그쪽에 둔다 (GPU-235).
  # 루트 EBS는 OS만 담는다. image_id가 없으므로 EKS가 만든 NodeConfig(클러스터 접속 정보)와 병합된다.
  # gpu_instance_types에는 인스턴스 스토어가 있는 유형(g4dn 등)만 넣는다.
  user_data = base64encode(local.gpu_user_data)

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
  node_role_arn   = module.gpu_node_role.arn
  # 워커는 클러스터에 배정된 AZ 하나에만 둔다 (컨트롤 플레인은 여러 AZ 서브넷 사용).
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

  # 업데이트는 한 대씩 먼저 내리고 교체한다 (GPU 쿼터를 넘는 증설 방지).
  update_config {
    max_unavailable = 1
    update_strategy = "MINIMAL"
  }

  depends_on = [
    module.gpu_node_role,
    aws_eks_addon.pod_identity_agent,
    aws_eks_addon.vpc_cni,
    aws_eks_addon.kube_proxy,
  ]

  tags = {
    Name     = "${var.cluster_name}-gpu-${each.key}"
    NodeRole = each.key
  }
}
