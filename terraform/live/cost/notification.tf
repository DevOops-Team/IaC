resource "aws_cloudwatch_log_group" "cost" {
  name              = "/aws/lambda/${local.name}"
  retention_in_days = 14
}

resource "aws_iam_role" "lambda" {
  name = "${local.name}-lambda"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy" "lambda" {
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = "s3:ListBucket", Resource = aws_s3_bucket.cost.arn, Condition = { StringLike = { "s3:prefix" = ["cur/*"] } } },
      { Effect = "Allow", Action = "s3:GetObject", Resource = "${aws_s3_bucket.cost.arn}/cur/*" },
      { Effect = "Allow", Action = "ssm:GetParameter", Resource = "arn:${data.aws_partition.current.partition}:ssm:${local.cfg.region}:${data.aws_caller_identity.current.account_id}:parameter${local.parameter}" },
      { Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "${aws_cloudwatch_log_group.cost.arn}:*" }
    ]
  })
}

data "archive_file" "lambda" {
  type        = "zip"
  source_file = "${path.module}/../../../scripts/cost/daily_cost.py"
  output_path = "${path.module}/artifacts/daily-cost.zip"
}

resource "aws_lambda_function" "cost" {
  function_name                  = local.name
  role                           = aws_iam_role.lambda.arn
  runtime                        = "python3.12"
  handler                        = "daily_cost.handler"
  filename                       = data.archive_file.lambda.output_path
  source_code_hash               = data.archive_file.lambda.output_base64sha256
  memory_size                    = 256
  timeout                        = 120
  reserved_concurrent_executions = 1
  environment {
    variables = {
      COST_BUCKET       = aws_s3_bucket.cost.bucket
      EXPORT_NAME       = local.export_name
      ACCOUNT_ID        = data.aws_caller_identity.current.account_id
      WEBHOOK_PARAMETER = local.parameter
      SLACK_CHANNEL     = "#aws-비용트래킹"
    }
  }
  depends_on = [aws_iam_role_policy.lambda, aws_cloudwatch_log_group.cost]
}

resource "aws_lambda_function_event_invoke_config" "cost" {
  function_name                = aws_lambda_function.cost.function_name
  maximum_event_age_in_seconds = 3600
  maximum_retry_attempts       = 0
}

resource "aws_scheduler_schedule_group" "cost" {
  name = local.name
}

resource "aws_iam_role" "scheduler" {
  name = "${local.name}-scheduler"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow", Principal = { Service = "scheduler.amazonaws.com" }, Action = "sts:AssumeRole",
      Condition = { StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id, "aws:SourceArn" = aws_scheduler_schedule_group.cost.arn } }
    }]
  })
}

resource "aws_iam_role_policy" "scheduler" {
  role = aws_iam_role.scheduler.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "lambda:InvokeFunction", Resource = aws_lambda_function.cost.arn }]
  })
}

resource "aws_scheduler_schedule" "cost" {
  name                         = "daily-0900-kst"
  group_name                   = aws_scheduler_schedule_group.cost.name
  schedule_expression          = "cron(0 9 * * ? *)"
  schedule_expression_timezone = "Asia/Seoul"
  state                        = var.schedule_enabled ? "ENABLED" : "DISABLED"
  flexible_time_window {
    mode = "OFF"
  }
  target {
    arn      = aws_lambda_function.cost.arn
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ source = "daily-schedule" })
    retry_policy {
      maximum_event_age_in_seconds = 3600
      maximum_retry_attempts       = 0
    }
  }
  depends_on = [aws_iam_role_policy.scheduler]
}
