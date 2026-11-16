variable "name_prefix" {
  type = string
}

variable "workload" {
  description = "Workload name. Certificate CN must be <name_prefix>-<workload>."
  type        = string
}

variable "account_id" {
  type = string
}

variable "trust_anchor_arn" {
  type = string
}

variable "policy_name" {
  type    = string
  default = null
}

variable "policy_json" {
  type    = string
  default = null
}
