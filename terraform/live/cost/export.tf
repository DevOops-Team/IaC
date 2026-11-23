resource "aws_s3_bucket" "cost" {
  bucket        = local.bucket
  force_destroy = false
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_public_access_block" "cost" {
  bucket                  = aws_s3_bucket.cost.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "cost" {
  bucket = aws_s3_bucket.cost.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cost" {
  bucket = aws_s3_bucket.cost.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# 최신 manifest는 고정 경로, CSV는 실행별 경로라 수집 중 보고서 갱신에도 섞이지 않는다.
resource "aws_s3_bucket_lifecycle_configuration" "cost" {
  bucket = aws_s3_bucket.cost.id
  rule {
    id     = "reports-90-days"
    status = "Enabled"
    filter {
      prefix = "cur/"
    }
    expiration {
      days = 90
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

resource "aws_s3_bucket_policy" "cost" {
  bucket = aws_s3_bucket.cost.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DataExportDelivery"
        Effect    = "Allow"
        Principal = { Service = ["bcm-data-exports.amazonaws.com", "billingreports.amazonaws.com"] }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.cost.arn}/*"
        Condition = {
          StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
          ArnLike = { "aws:SourceArn" = [
            "arn:${data.aws_partition.current.partition}:bcm-data-exports:us-east-1:${data.aws_caller_identity.current.account_id}:export/*",
            "arn:${data.aws_partition.current.partition}:cur:us-east-1:${data.aws_caller_identity.current.account_id}:definition/*"
          ] }
        }
      },
      {
        # AWS Billing 공식 전달 정책: export 생성 때 버킷 소유권·정책 검증에도 필요하다.
        Sid       = "BillingDeliveryValidation"
        Effect    = "Allow"
        Principal = { Service = ["bcm-data-exports.amazonaws.com", "billingreports.amazonaws.com"] }
        Action    = ["s3:GetBucketAcl", "s3:GetBucketPolicy"]
        Resource  = aws_s3_bucket.cost.arn
        Condition = {
          StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
          ArnLike = { "aws:SourceArn" = [
            "arn:${data.aws_partition.current.partition}:bcm-data-exports:us-east-1:${data.aws_caller_identity.current.account_id}:export/*",
            "arn:${data.aws_partition.current.partition}:cur:us-east-1:${data.aws_caller_identity.current.account_id}:definition/*"
          ] }
        }
      },
      {
        Sid       = "TLSOnly"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.cost.arn, "${aws_s3_bucket.cost.arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      }
    ]
  })
}

resource "aws_bcmdataexports_export" "hourly" {
  provider = aws.billing
  export {
    name = local.export_name
    data_query {
      query_statement = <<-SQL
        SELECT bill_billing_period_start_date, line_item_usage_account_id,
          line_item_line_item_type, line_item_usage_start_date,
          line_item_usage_end_date, line_item_product_code, line_item_usage_type,
          line_item_currency_code, line_item_unblended_cost, line_item_net_unblended_cost
        FROM COST_AND_USAGE_REPORT
        WHERE line_item_usage_account_id = '${data.aws_caller_identity.current.account_id}'
      SQL
      table_configurations = {
        COST_AND_USAGE_REPORT = {
          BILLING_VIEW_ARN                      = "arn:${data.aws_partition.current.partition}:billing::${data.aws_caller_identity.current.account_id}:billingview/primary"
          TIME_GRANULARITY                      = "HOURLY"
          INCLUDE_RESOURCES                     = "FALSE"
          INCLUDE_SPLIT_COST_ALLOCATION_DATA    = "FALSE"
          INCLUDE_MANUAL_DISCOUNT_COMPATIBILITY = "FALSE"
        }
      }
    }
    destination_configurations {
      s3_destination {
        s3_bucket = aws_s3_bucket.cost.bucket
        s3_prefix = "cur"
        s3_region = local.cfg.region
        s3_output_configurations {
          overwrite   = "CREATE_NEW_REPORT"
          format      = "TEXT_OR_CSV"
          compression = "GZIP"
          output_type = "CUSTOM"
        }
      }
    }
    refresh_cadence {
      frequency = "SYNCHRONOUS"
    }
  }
  depends_on = [aws_s3_bucket_policy.cost, aws_s3_bucket_ownership_controls.cost, aws_s3_bucket_public_access_block.cost]
}
