output "checkpoint_bucket_name" {
  value = aws_s3_bucket.checkpoint.id
}

output "checkpoint_bucket_arn" {
  value = aws_s3_bucket.checkpoint.arn
}

output "fencing_table_name" {
  value = aws_dynamodb_table.fencing.name
}

output "fencing_table_arn" {
  value = aws_dynamodb_table.fencing.arn
}