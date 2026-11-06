resource "aws_s3_bucket" "checkpoint" {
  bucket        = local.checkpoint_bucket_name
  force_destroy = false

  tags = {
    Name = local.checkpoint_bucket_name
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "checkpoint" {
  bucket = aws_s3_bucket.checkpoint.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "checkpoint" {
  bucket = aws_s3_bucket.checkpoint.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "checkpoint" {
  bucket = aws_s3_bucket.checkpoint.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "checkpoint" {
  bucket = aws_s3_bucket.checkpoint.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_policy" "checkpoint" {
  bucket = aws_s3_bucket.checkpoint.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.checkpoint.arn,
          "${aws_s3_bucket.checkpoint.arn}/*"
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })
}