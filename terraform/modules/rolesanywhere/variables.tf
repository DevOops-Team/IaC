variable "name_prefix" {
  type = string
}

variable "account_id" {
  type = string
}

variable "ca_certificate_pem" {
  description = "발급 CA의 공개 인증서 (PEM). 개인 키 금지."
  type        = string
  validation {
    condition     = can(regex("-----BEGIN CERTIFICATE-----", var.ca_certificate_pem))
    error_message = "PEM 형식의 CA 공개 인증서여야 한다."
  }
}

variable "additional_ca_certificates" {
  description = "추가로 믿을 CA 이름 => 공개 인증서(PEM). 이름마다 trust anchor <prefix>-onprem-ca-<이름>."
  type        = map(string)
  default     = {}
  validation {
    condition     = alltrue([for pem in values(var.additional_ca_certificates) : can(regex("-----BEGIN CERTIFICATE-----", pem))])
    error_message = "PEM 형식의 CA 공개 인증서여야 한다."
  }
}

variable "workloads" {
  description = "워크로드 이름 => 인라인 정책(이름 · JSON). 정책이 없으면 역할 · profile만 만든다."
  type = map(object({
    policy_name = optional(string)
    policy_json = optional(string)
  }))
}
