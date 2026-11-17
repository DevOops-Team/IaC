variable "name_prefix" {
  type = string
}

variable "workload" {
  description = "워크로드 이름. 인증서 CN은 <name_prefix>-<workload>여야 한다."
  type        = string
}

variable "account_id" {
  type = string
}

variable "trust_anchor_arns" {
  description = "이 역할을 맡을 수 있는 trust anchor ARN 목록."
  type        = list(string)
}

variable "policy_name" {
  type    = string
  default = null
}

variable "policy_json" {
  type    = string
  default = null
}
