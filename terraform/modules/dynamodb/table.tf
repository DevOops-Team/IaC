resource "aws_dynamodb_table" "this" {
  name         = var.name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = var.hash_key

  deletion_protection_enabled = true

  attribute {
    name = var.hash_key
    type = "S"
  }

  point_in_time_recovery {
    enabled                 = true
    recovery_period_in_days = var.pitr_days
  }

  tags = {
    Name = var.name
  }

  lifecycle {
    prevent_destroy = true
  }
}
