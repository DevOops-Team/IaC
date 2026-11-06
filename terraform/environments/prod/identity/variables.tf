variable "project_name" {
  type    = string
  default = "devoops"
}

variable "environment" {
  type    = string
  default = "prod"
}

variable "ca_certificate_path" {
  description = "Absolute path to the PUBLIC issuing CA certificate. Never pass a private key."
  type        = string
  validation {
    condition     = can(regex("-----BEGIN CERTIFICATE-----", file(var.ca_certificate_path)))
    error_message = "Provide an existing PEM public CA certificate file."
  }
}
