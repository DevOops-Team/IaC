# 인증서 CN이 <prefix>-<workload>이고 우리 trust anchor로 들어온 세션만 이 역할을 맡을 수 있다.
resource "aws_iam_role" "this" {
  name                 = "${var.name_prefix}-onprem-${var.workload}"
  max_session_duration = 3600

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "rolesanywhere.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:SetSourceIdentity", "sts:TagSession"]
      Condition = {
        ArnEquals = { "aws:SourceArn" = var.trust_anchor_arn }
        StringEquals = {
          "aws:SourceAccount"               = var.account_id
          "aws:PrincipalTag/x509Subject/CN" = "${var.name_prefix}-${var.workload}"
        }
      }
    }]
  })
}

resource "aws_rolesanywhere_profile" "this" {
  name             = "${var.name_prefix}-${var.workload}"
  enabled          = true
  duration_seconds = 3600
  role_arns        = [aws_iam_role.this.arn]
}

resource "aws_iam_role_policy" "this" {
  count  = var.policy_json == null ? 0 : 1
  name   = var.policy_name
  role   = aws_iam_role.this.id
  policy = var.policy_json
}
