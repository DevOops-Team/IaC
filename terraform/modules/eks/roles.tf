# 이 클러스터의 IAM 역할 (role/). 노드 역할은 S3 · DynamoDB를 못 쓴다: Pod는 trainer · aws-node 전용 역할을 쓴다.
locals {
  pod_identity  = { service = "pods.eks.amazonaws.com", actions = ["sts:AssumeRole", "sts:TagSession"] }
  node_policies = ["AmazonEKSWorkerNodePolicy", "AmazonEC2ContainerRegistryPullOnly"]
}

# EKS 컨트롤 플레인
module "cluster_role" {
  source           = "./role"
  name             = "${var.cluster_name}-cluster-role"
  service          = "eks.amazonaws.com"
  managed_policies = ["AmazonEKSClusterPolicy"]
}

# 시스템 CPU 노드
module "cpu_node_role" {
  source           = "./role"
  name             = "${var.cluster_name}-cpu-node-role"
  service          = "ec2.amazonaws.com"
  managed_policies = local.node_policies
}

# GPU 노드 (학습 · 예비 그룹 공통)
module "gpu_node_role" {
  source           = "./role"
  name             = "${var.cluster_name}-gpu-node-role"
  service          = "ec2.amazonaws.com"
  managed_policies = local.node_policies
}

# kube-system/aws-node (VPC CNI) Pod Identity
module "vpc_cni_role" {
  source  = "./role"
  name    = "${var.cluster_name}-vpc-cni-role"
  service = local.pod_identity.service
  actions = local.pod_identity.actions
  string_equals = {
    "aws:RequestTag/eks-cluster-arn"            = aws_eks_cluster.this.arn
    "aws:RequestTag/kubernetes-namespace"       = "kube-system"
    "aws:RequestTag/kubernetes-service-account" = "aws-node"
  }
  managed_policies = ["AmazonEKS_CNI_Policy"]
}

# training/trainer Pod Identity: init · sidecar · trainer가 같은 SA를 쓰므로 권한을 합쳐 준다
module "trainer_role" {
  source  = "./role"
  name    = "${var.cluster_name}-trainer-role"
  service = local.pod_identity.service
  actions = local.pod_identity.actions
  string_equals = {
    "aws:RequestTag/eks-cluster-arn"            = aws_eks_cluster.this.arn
    "aws:RequestTag/kubernetes-namespace"       = "training"
    "aws:RequestTag/kubernetes-service-account" = "trainer"
  }
  inline_policies = {
    "training-data-access" = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Sid      = "LocateTrainingBucket"
          Effect   = "Allow"
          Action   = "s3:GetBucketLocation"
          Resource = var.checkpoint_bucket_arn
        },
        {
          Sid      = "ListTrainingPrefixes"
          Effect   = "Allow"
          Action   = "s3:ListBucket"
          Resource = var.checkpoint_bucket_arn
          Condition = {
            StringLike = {
              "s3:prefix" = ["code/", "code/*", "datasets/", "datasets/*", "jobs/", "jobs/*"]
            }
          }
        },
        {
          Sid    = "ReadConfigurationDatasetsAndCheckpoints"
          Effect = "Allow"
          Action = "s3:GetObject"
          Resource = [
            "${var.checkpoint_bucket_arn}/code/*",
            "${var.checkpoint_bucket_arn}/datasets/*",
            "${var.checkpoint_bucket_arn}/jobs/*",
          ]
        },
        {
          Sid      = "UploadCheckpoints"
          Effect   = "Allow"
          Action   = ["s3:PutObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"]
          Resource = "${var.checkpoint_bucket_arn}/jobs/*"
        },
        {
          Sid      = "ReadAndConditionallyUpdateFencing"
          Effect   = "Allow"
          Action   = ["dynamodb:GetItem", "dynamodb:UpdateItem"]
          Resource = var.fencing_table_arn
        },
      ]
    })
  }
}
