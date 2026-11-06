# The init containers, sidecars and trainer share one Pod ServiceAccount.
# Pod Identity assigns the union of their AWS permissions to training/trainer.
resource "aws_iam_role" "trainer" {
  name = "${var.cluster_name}-trainer-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
      Condition = {
        StringEquals = {
          "aws:RequestTag/eks-cluster-arn"            = aws_eks_cluster.this.arn
          "aws:RequestTag/kubernetes-namespace"       = "training"
          "aws:RequestTag/kubernetes-service-account" = "trainer"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "trainer" {
  name = "training-data-access"
  role = aws_iam_role.trainer.id

  policy = jsonencode({
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

resource "aws_eks_pod_identity_association" "trainer" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = "training"
  service_account = "trainer"
  role_arn        = aws_iam_role.trainer.arn

  depends_on = [
    aws_iam_role_policy.trainer,
    aws_eks_addon.pod_identity_agent,
  ]
}
