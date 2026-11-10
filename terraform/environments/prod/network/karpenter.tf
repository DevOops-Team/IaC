locals {
  karpenter_namespace       = "kube-system"
  karpenter_service_account = "karpenter"
  karpenter_gpu_nodepool    = "gpu-training"
  karpenter_gpu_label       = "node-role.devoops.site/gpu"
  karpenter_gpu_taint       = "nvidia.com/gpu"

  # EKS 1.35 AL2023 NVIDIA x86_64, release v20261107 in us-east-2.
  karpenter_gpu_ami_id = "ami-0d4128280e9fe7fbc"
}

data "aws_iam_policy_document" "karpenter_trust" {
  statement {
    sid     = "PodIdentity"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/eks-cluster-arn"
      values   = [module.eks_a.cluster_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-namespace"
      values   = [local.karpenter_namespace]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-service-account"
      values   = [local.karpenter_service_account]
    }
  }
}

module "karpenter_a" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "21.25.0"

  cluster_name    = module.eks_a.cluster_name
  namespace       = local.karpenter_namespace
  service_account = local.karpenter_service_account

  iam_role_name      = "${module.eks_a.cluster_name}-karpenter"
  iam_policy_name    = "${module.eks_a.cluster_name}-karpenter"
  node_iam_role_name = "${module.eks_a.cluster_name}-karpenter-node"
  queue_name         = "${module.eks_a.cluster_name}-karpenter"

  # The module appends the event type and the provider appends a unique suffix.
  rule_name_prefix = "${replace(module.eks_a.cluster_name, "-eks-", "-")}-"

  iam_role_override_assume_policy_documents = [data.aws_iam_policy_document.karpenter_trust.json]
  # The controller policy exceeds the IAM managed policy size limit.
  enable_inline_policy            = true
  create_pod_identity_association = true
  enable_spot_termination         = true
  create_access_entry             = true
  create_instance_profile         = true

  # The aws-node DaemonSet already has its own EKS Pod Identity role.
  node_iam_role_attach_cni_policy = false
}
