locals {
  name_prefix = "${var.project_name}-${var.environment}"
  account_id  = "354363695096"
  region      = "us-east-2"
  bucket_arn  = "arn:aws:s3:::${local.name_prefix}-ckpt-${local.account_id}-${local.region}"
  fencing_arn = "arn:aws:dynamodb:${local.region}:${local.account_id}:table/${local.name_prefix}-fencing"
  cluster_arn = "arn:aws:eks:${local.region}:${local.account_id}:cluster/${local.name_prefix}-eks-a"
  workloads   = toset(["backend", "recovery", "relocator", "multikueue"])
}

resource "aws_rolesanywhere_trust_anchor" "onprem" {
  name    = "${local.name_prefix}-onprem-ca"
  enabled = true
  source {
    source_type = "CERTIFICATE_BUNDLE"
    source_data {
      x509_certificate_data = file(var.ca_certificate_path)
    }
  }
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_iam_role" "onprem" {
  for_each             = local.workloads
  name                 = "${local.name_prefix}-onprem-${each.key}"
  max_session_duration = 3600

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "rolesanywhere.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:SetSourceIdentity", "sts:TagSession"]
      Condition = {
        ArnEquals = { "aws:SourceArn" = aws_rolesanywhere_trust_anchor.onprem.arn }
        StringEquals = {
          "aws:SourceAccount"               = local.account_id
          "aws:PrincipalTag/x509Subject/CN" = "${local.name_prefix}-${each.key}"
        }
      }
    }]
  })
}

resource "aws_rolesanywhere_profile" "onprem" {
  for_each         = local.workloads
  name             = "${local.name_prefix}-${each.key}"
  enabled          = true
  duration_seconds = 3600
  role_arns        = [aws_iam_role.onprem[each.key].arn]
}
