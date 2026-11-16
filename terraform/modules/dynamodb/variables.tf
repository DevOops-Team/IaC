variable "name" {
  type = string
}

variable "hash_key" {
  description = "Partition key (string)."
  type        = string
}

variable "pitr_days" {
  description = "Point-in-time recovery window in days."
  type        = number
  default     = 35
}
