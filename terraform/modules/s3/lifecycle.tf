resource "aws_s3_bucket_lifecycle_configuration" "this" {
  count  = length(var.lifecycle_rules) > 0 ? 1 : 0
  bucket = aws_s3_bucket.this.id

  dynamic "rule" {
    for_each = var.lifecycle_rules
    content {
      id     = rule.value.id
      status = "Enabled"

      dynamic "filter" {
        for_each = rule.value.prefix == null ? [] : [rule.value.prefix]
        content {
          prefix = filter.value
        }
      }
      dynamic "filter" {
        for_each = rule.value.prefix == null ? [true] : []
        content {}
      }

      dynamic "expiration" {
        for_each = rule.value.expiration_days != null || rule.value.expired_object_delete_marker != null ? [true] : []
        content {
          days                         = rule.value.expiration_days
          expired_object_delete_marker = rule.value.expired_object_delete_marker
        }
      }

      dynamic "noncurrent_version_expiration" {
        for_each = rule.value.noncurrent_expiration_days == null ? [] : [rule.value.noncurrent_expiration_days]
        content {
          noncurrent_days = noncurrent_version_expiration.value
        }
      }

      dynamic "abort_incomplete_multipart_upload" {
        for_each = rule.value.abort_incomplete_multipart_days == null ? [] : [rule.value.abort_incomplete_multipart_days]
        content {
          days_after_initiation = abort_incomplete_multipart_upload.value
        }
      }
    }
  }

  depends_on = [aws_s3_bucket_versioning.this]
}
