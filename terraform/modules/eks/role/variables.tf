variable "name" {
  description = "IAM role name."
  type        = string
}

variable "service" {
  description = "AWS service principal that assumes this role (e.g. eks.amazonaws.com)."
  type        = string
}

variable "actions" {
  type    = list(string)
  default = ["sts:AssumeRole"]
}

variable "string_equals" {
  description = "Trust policy StringEquals conditions (Pod Identity의 클러스터 · 네임스페이스 · SA 제한 등)."
  type        = map(string)
  default     = {}
}

variable "managed_policies" {
  description = "AWS managed policy names (arn:aws:iam::aws:policy/<name>)."
  type        = list(string)
  default     = []
}

variable "inline_policies" {
  description = "Inline policy name => JSON document."
  type        = map(string)
  default     = {}
}
