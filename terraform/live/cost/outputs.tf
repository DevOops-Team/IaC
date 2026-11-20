output "cost_bucket" {
  value = aws_s3_bucket.cost.bucket
}
output "webhook_parameter" {
  value = local.parameter
}
output "function_name" {
  value = aws_lambda_function.cost.function_name
}
output "schedule_enabled" {
  value = var.schedule_enabled
}
output "export_arn" {
  value = aws_bcmdataexports_export.hourly.arn
}
