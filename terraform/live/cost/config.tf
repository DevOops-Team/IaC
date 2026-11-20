variable "environment" {
  type    = string
  default = "prod"
}

variable "schedule_enabled" {
  description = "Webhook 저장과 실제 전송 검증 후 true로 켠다. CUR 수집은 먼저 시작한다."
  type        = bool
  default     = false
}

locals {
  cfg         = yamldecode(file("${path.root}/../../config/${var.environment}.yaml"))
  prefix      = "${local.cfg.project}-${local.cfg.environment}"
  name        = "${local.prefix}-daily-cost"
  export_name = "${local.prefix}-cost-hourly"
  parameter   = "/${local.cfg.project}/${local.cfg.environment}/cost/slack-webhook"
  bucket      = "${local.prefix}-cost-${data.aws_caller_identity.current.account_id}-${local.cfg.region}"
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

provider "aws" {
  region = local.cfg.region
  default_tags {
    tags = {
      Project     = local.cfg.project
      Environment = local.cfg.environment
      ManagedBy   = "Terraform"
    }
  }
}

provider "aws" {
  alias  = "billing"
  region = "us-east-1"
}
