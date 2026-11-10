locals {
  monitoring_workloads  = toset(["mimir", "loki", "tempo"])
  monitoring_bucket_arn = "arn:aws:s3:::${local.name_prefix}-monitoring-${local.account_id}-${local.region}"
}

resource "aws_iam_role_policy" "monitoring" {
  for_each = local.monitoring_workloads

  name = "${each.key}-s3-access"
  role = aws_iam_role.onprem[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListOwnPrefix"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = local.monitoring_bucket_arn
        Condition = {
          StringLike = {
            "s3:prefix" = "${each.key}/*"
          }
        }
      },
      {
        Sid    = "ManageOwnObjects"
        Effect = "Allow"
        Action = concat([
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts",
        ], each.key == "tempo" ? ["s3:GetObjectTagging", "s3:PutObjectTagging"] : [])
        Resource = "${local.monitoring_bucket_arn}/${each.key}/*"
      },
    ]
  })
}
