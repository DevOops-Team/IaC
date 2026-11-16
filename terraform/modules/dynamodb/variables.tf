variable "name" {
  type = string
}

variable "hash_key" {
  description = "파티션 키 이름 (문자열 타입)."
  type        = string
}

variable "pitr_days" {
  description = "시점 복구(PITR) 보관 일수."
  type        = number
  default     = 35
}
