output "state_bucket_name" {
  value = aws_s3_bucket.state.id
}

output "state_keys" {
  value = { for name in local.root_names : name => "prod/${name}/terraform.tfstate" }
}

# Reference for future SSO permission sets/CI roles. It is not attached to any
# application role and does not include deployment permissions for AWS resources.
output "backend_access_policy_json" {
  value = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = aws_s3_bucket.state.arn
      },
      {
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject"]
        Resource = [
          for name in local.root_names : "${aws_s3_bucket.state.arn}/prod/${name}/terraform.tfstate"
        ]
      },
      {
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = [
          for name in local.root_names : "${aws_s3_bucket.state.arn}/prod/${name}/terraform.tfstate.tflock"
        ]
      },
    ]
  })
}
