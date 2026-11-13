# GPU-128 / ADR-31: the database VM uploads backups only.
# Restore downloads use the operator's SSO identity, not this workload role.
resource "aws_iam_role_policy" "db_backup" {
  name = "db-backup-write-only"
  role = aws_iam_role.onprem["db-backup"].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "UploadDatabaseBackups"
      Effect = "Allow"
      Action = [
        "s3:PutObject",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts",
      ]
      Resource = "${local.bucket_arn}/backups/db/*"
    }]
  })
}
