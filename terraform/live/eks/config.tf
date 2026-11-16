# 값은 config/<environment>.yaml에서 읽고, 계정 ID는 aws sts로 읽는다.
variable "environment" {
  description = "config/<environment>.yaml을 고른다."
  type        = string
  default     = "prod"
}

variable "deployment_profile" {
  description = "토폴로지 이름 (test | full). 비우면 config eks.topology. run.sh --topology가 넘긴다."
  type        = string
  default     = null
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
