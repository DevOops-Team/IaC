variable "name_prefix" {
  type = string
}

variable "account_id" {
  type = string
}

variable "ca_certificate_pem" {
  description = "PUBLIC issuing CA certificate (PEM). Never a private key."
  type        = string
  validation {
    condition     = can(regex("-----BEGIN CERTIFICATE-----", var.ca_certificate_pem))
    error_message = "Provide a PEM public CA certificate."
  }
}

variable "workloads" {
  description = "워크로드 이름 => 인라인 정책(이름 · JSON). 정책이 없으면 역할과 profile만 만든다."
  type = map(object({
    policy_name = optional(string)
    policy_json = optional(string)
  }))
}
