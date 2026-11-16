variable "name" {
  description = "Bucket name (globally unique)."
  type        = string
}

variable "versioning" {
  description = "Enable object versioning."
  type        = bool
  default     = false
}

variable "bucket_owner_enforced" {
  description = "Disable ACLs (BucketOwnerEnforced)."
  type        = bool
  default     = false
}

variable "lifecycle_rules" {
  description = "Lifecycle rules. prefix가 없으면 버킷 전체. 값이 없는 항목은 그 동작을 넣지 않는다."
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
