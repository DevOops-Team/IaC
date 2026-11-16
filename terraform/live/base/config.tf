# 설정은 terraform/config/<environment>.yaml 한 곳 (사람이 고치는 값). 계정 ID는 aws sts로 읽는다.
variable "environment" {
  description = "config/<environment>.yaml을 고른다."
  type        = string
  default     = "prod"
}

locals {
  cfg         = yamldecode(file("${path.root}/../../config/${var.environment}.yaml"))
  name_prefix = "${local.cfg.project}-${local.cfg.environment}"
}

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = local.cfg.region
}
