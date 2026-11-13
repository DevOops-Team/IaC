# GPU-128 / ADR-31: keep database backup expiration separate from jobs/.
resource "aws_s3_bucket_lifecycle_configuration" "database_backups" {
  bucket = aws_s3_bucket.checkpoint.id

  rule {
    id     = "database-backups-30-days"
    status = "Enabled"

    filter {
      prefix = "backups/db/"
    }

    expiration {
      days = 30
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }

  rule {
    id     = "database-backups-expired-delete-markers"
    status = "Enabled"

    filter {
      prefix = "backups/db/"
    }

    expiration {
      expired_object_delete_marker = true
    }
  }

  depends_on = [aws_s3_bucket_versioning.checkpoint]
}
