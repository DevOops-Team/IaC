output "trainer_role_arn" {
  description = "training/trainer ServiceAccount의 Pod Identity 역할 ARN."
  value       = module.trainer_role.arn
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

output "service_ipv4_cidr" {
  value = var.service_ipv4_cidr
}

output "cpu_node_group_name" {
  value = aws_eks_node_group.cpu.node_group_name
}

output "cpu_configuration" {
  value = {
    capacity_type  = aws_eks_node_group.cpu.capacity_type
    instance_types = aws_eks_node_group.cpu.instance_types
    scaling        = aws_eks_node_group.cpu.scaling_config[0]
  }
}

output "managed_gpu_node_groups" {
  description = "고정 GPU 노드그룹 구성 (Karpenter 없음)."
  value = {
    for role, group in aws_eks_node_group.gpu : role => {
      name           = group.node_group_name
      capacity_type  = group.capacity_type
      instance_types = group.instance_types
      scaling        = group.scaling_config[0]
      labels         = group.labels
      taints         = group.taint
      az             = var.cpu_node_az
    }
  }
}

output "cluster_certificate_authority_data" {
  description = "클러스터 API CA (base64, kubeconfig certificate-authority-data)."
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "admin_access_policy_association_id" {
  description = "관리자 Access Entry 연결 ID. 허브 등록이 이 값이 생긴 뒤에 시작한다."
  value       = aws_eks_access_policy_association.admin.id
}
