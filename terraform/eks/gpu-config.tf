locals {
  eks_modules = merge({
    a = module.eks_a
    b = module.eks_b
  }, { for cluster in module.eks_c : "c" => cluster })
}

output "deployment_profile" {
  value = var.deployment_profile
}

output "eks_clusters" {
  description = "Private EKS endpoints, per-cluster identities, and fixed managed GPU groups."
  value = {
    for alias, cluster in local.eks_modules : alias => {
      name             = cluster.cluster_name
      arn              = cluster.cluster_arn
      endpoint         = cluster.cluster_endpoint
      service_cidr     = cluster.service_ipv4_cidr
      cpu_node_group   = cluster.cpu_node_group_name
      cpu              = cluster.cpu_configuration
      trainer_role_arn = cluster.trainer_role_arn
      pod_identity_id  = cluster.trainer_pod_identity_association_id
      gpu_node_groups  = cluster.managed_gpu_node_groups
    }
  }
}

output "gpu_bootstrap" {
  description = "Kubernetes owner installs the NVIDIA plugin per cluster; no Karpenter or NodePool."
  value = {
    device_plugin_version = "0.20.1"
    device_plugin_values = yamlencode({
      nodeSelector = { "devoops/gpu" = "true" }
      affinity     = null
      tolerations = [
        { key = "nvidia.com/gpu", operator = "Exists", effect = "NoSchedule" },
        { key = "devoops/spare", operator = "Equal", value = "true", effect = "NoSchedule" },
      ]
    })
    clusters = { for alias, cluster in local.eks_modules : alias => cluster.cluster_name }
  }
}
