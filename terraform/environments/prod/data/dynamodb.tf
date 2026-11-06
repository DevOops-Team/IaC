resource "aws_dynamodb_table" "fencing" {
  name         = local.fencing_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "job_id"

  deletion_protection_enabled = true

  attribute {
    name = "job_id"
    type = "S"
  }

  point_in_time_recovery {
    enabled                 = true
    recovery_period_in_days = 35
  }

  tags = {
    Name = local.fencing_table_name
  }

  lifecycle {
    prevent_destroy = true
  }
}