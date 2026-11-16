output "state_bucket_name" {
  value = aws_s3_bucket.state.id
}

output "state_keys" {
  value = { for name in local.root_names : name => "${local.cfg.environment}/${name}/terraform.tfstate" }
}

# 나중에 SSO 권한 세트 · CI 역할에 붙일 참고용 최소 정책 (state 읽기 · 쓰기 · 잠금만). 어디에도 붙어 있지 않다.
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
          for name in local.root_names : "${aws_s3_bucket.state.arn}/${local.cfg.environment}/${name}/terraform.tfstate"
        ]
      },
      {
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = [
          for name in local.root_names : "${aws_s3_bucket.state.arn}/${local.cfg.environment}/${name}/terraform.tfstate.tflock"
        ]
      },
    ]
  })
}
