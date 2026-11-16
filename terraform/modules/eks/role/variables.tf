variable "name" {
  description = "IAM 역할 이름."
  type        = string
}

variable "service" {
  description = "이 역할을 맡는 AWS 서비스 (예: eks.amazonaws.com)."
  type        = string
}

variable "actions" {
  type    = list(string)
  default = ["sts:AssumeRole"]
}

variable "string_equals" {
  description = "신뢰 정책 StringEquals 조건 (Pod Identity의 클러스터 · 네임스페이스 · SA 제한)."
  type        = map(string)
  default     = {}
}

variable "managed_policies" {
  description = "붙일 AWS 관리형 정책 이름 (arn:aws:iam::aws:policy/<name>)."
  type        = list(string)
  default     = []
}

variable "inline_policies" {
  description = "인라인 정책 이름 => JSON."
  type        = map(string)
  default     = {}
}
