variable "name" {
  description = "버킷 이름 (전 세계에서 유일)."
  type        = string
}

variable "versioning" {
  description = "객체 버전 관리 사용."
  type        = bool
  default     = false
}

variable "bucket_owner_enforced" {
  description = "ACL 끄기 (BucketOwnerEnforced)."
  type        = bool
  default     = false
}

variable "lifecycle_rules" {
  description = "수명 주기 규칙. prefix가 없으면 버킷 전체, 비운 항목은 그 동작을 넣지 않는다."
  type = list(object({
    id                              = string
    prefix                          = optional(string)
    expiration_days                 = optional(number)
    expired_object_delete_marker    = optional(bool)
    noncurrent_expiration_days      = optional(number)
    abort_incomplete_multipart_days = optional(number)
  }))
  default = []
}

variable "cors_rules" {
  description = "CORS 규칙. 비우면 CORS 설정을 만들지 않는다 (브라우저가 버킷에 직접 접근하지 않음)."
  type = list(object({
    id              = optional(string)
    allowed_origins = list(string)
    allowed_methods = list(string)
    allowed_headers = optional(list(string), [])
    expose_headers  = optional(list(string), [])
    max_age_seconds = optional(number)
  }))
  default = []
}
