# Only operations identified in the reviewed contract. Pending EC2/progress APIs
# are deliberately not guessed. All resources belong to this prod environment.
resource "aws_iam_role_policy" "backend" {
  name = "backend-data-access"
  role = aws_iam_role.onprem["backend"].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "WriteSubmissionAndDatasets"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"]
        Resource = ["${local.bucket_arn}/code/*", "${local.bucket_arn}/datasets/*"]
      },
      {
        Sid      = "CreateAndReadInitialFencing"
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:GetItem"]
        Resource = local.fencing_arn
      },
    ]
  })
}

resource "aws_iam_role_policy" "recovery" {
  name = "recovery-fencing-access"
  role = aws_iam_role.onprem["recovery"].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "ManageRecoveryState"
      Effect   = "Allow"
      Action   = ["dynamodb:GetItem", "dynamodb:UpdateItem"]
      Resource = local.fencing_arn
    }]
  })
}

resource "aws_iam_role_policy" "relocator" {
  name = "relocator-data-access"
  role = aws_iam_role.onprem["relocator"].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "UpdateRelocationState"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:UpdateItem"]
        Resource = local.fencing_arn
      },
      {
        Sid      = "ReadSubmittedJobSet"
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "${local.bucket_arn}/code/*/jobset.json"
      },
      {
        Sid      = "DescribeWorkerInstances"
        Effect   = "Allow"
        Action   = "ec2:DescribeInstances"
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:RequestedRegion" = local.region
          }
        }
      },
      {
        Sid      = "DiscoverWorkerCluster"
        Effect   = "Allow"
        Action   = "eks:DescribeCluster"
        Resource = local.cluster_arns
      },
    ]
  })
}

resource "aws_iam_role_policy" "multikueue" {
  name = "worker-cluster-discovery"
  role = aws_iam_role.onprem["multikueue"].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "eks:DescribeCluster"
      Resource = local.cluster_arns
    }]
  })
}
