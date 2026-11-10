output "karpenter_gpu" {
  description = "Pinned Helm settings and GPU resources to install from a client that can reach the private EKS API."
  value = {
    cluster_name          = module.eks_a.cluster_name
    namespace             = local.karpenter_namespace
    karpenter_version     = "1.15.1"
    device_plugin_version = "0.20.1"
    controller_values = yamlencode({
      replicas = 1
      nodeSelector = {
        workload = "system"
      }
      serviceAccount = {
        name = local.karpenter_service_account
      }
      settings = {
        clusterName       = module.eks_a.cluster_name
        clusterEndpoint   = module.eks_a.cluster_endpoint
        interruptionQueue = module.karpenter_a.queue_name
      }
    })
    device_plugin_values = yamlencode({
      nodeSelector = {
        (local.karpenter_gpu_label) = "true"
      }
      # Select the project's GPU label without depending on Node Feature Discovery.
      affinity = null
      tolerations = [{
        key      = local.karpenter_gpu_taint
        operator = "Exists"
        effect   = "NoSchedule"
      }]
    })
    manifests = join("---\n", [
      yamlencode({
        apiVersion = "karpenter.k8s.aws/v1"
        kind       = "EC2NodeClass"
        metadata   = { name = local.karpenter_gpu_nodepool }
        spec = {
          amiFamily           = "AL2023"
          amiSelectorTerms    = [{ id = local.karpenter_gpu_ami_id }]
          instanceProfile     = module.karpenter_a.instance_profile_name
          subnetSelectorTerms = [for subnet in aws_subnet.private : { id = subnet.id }]
          securityGroupSelectorTerms = [{
            id = module.eks_a.cluster_primary_security_group_id
          }]
          associatePublicIPAddress = false
          blockDeviceMappings = [{
            deviceName = "/dev/xvda"
            ebs = {
              volumeSize          = "20Gi"
              volumeType          = "gp3"
              encrypted           = true
              deleteOnTermination = true
            }
          }]
          tags = {
            Project     = var.project_name
            Environment = var.environment
          }
        }
      }),
      yamlencode({
        apiVersion = "karpenter.sh/v1"
        kind       = "NodePool"
        metadata   = { name = local.karpenter_gpu_nodepool }
        spec = {
          limits = {
            cpu              = "8"
            "nvidia.com/gpu" = "2"
          }
          disruption = {
            consolidationPolicy = "WhenEmpty"
            consolidateAfter    = "5m"
          }
          template = {
            metadata = {
              labels = { (local.karpenter_gpu_label) = "true" }
            }
            spec = {
              nodeClassRef = {
                group = "karpenter.k8s.aws"
                kind  = "EC2NodeClass"
                name  = local.karpenter_gpu_nodepool
              }
              taints = [{
                key    = local.karpenter_gpu_taint
                value  = "true"
                effect = "NoSchedule"
              }]
              requirements = [
                { key = "node.kubernetes.io/instance-type", operator = "In", values = ["g4dn.xlarge"] },
                { key = "karpenter.sh/capacity-type", operator = "In", values = ["spot"] },
              ]
            }
          }
        }
      }),
    ])
  }
}
