locals {
  state_bucket_name = "${local.name_prefix}-tfstate-${local.account_id}-${local.region}"
  # 삭제를 막을 state 키 (run.sh state_key와 같아야 함). 이 root 자신은 처음 이름 bootstrap.
  # data · identity는 live/base로 합치기 전 키(11/16), 기록 보호용으로 남긴다.
  root_names = ["bootstrap", "base", "eks", "cost", "data", "identity"]
}

resource "aws_s3_bucket" "state" {
  bucket        = local.state_bucket_name
  force_destroy = false
  tags          = { Name = local.state_bucket_name }
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
      {
        # 잠금 파일(.tflock)은 지울 수 있어야 하므로 state 파일만 막는다
        Sid       = "ProtectStateHistoryFromDeletion"
        Effect    = "Deny"
        Principal = "*"
        Action    = ["s3:DeleteObject", "s3:DeleteObjectVersion"]
        Resource = [
          for name in local.root_names : "${aws_s3_bucket.state.arn}/${local.cfg.environment}/${name}/terraform.tfstate"
        ]
      },
    ]
  })
}
