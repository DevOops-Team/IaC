# 레포에 두지 않는 로컬 값 (run.sh가 넘기거나 terraform.local.tfvars)
variable "ca_certificate_path" {
  description = "Roles Anywhere CA 공개 인증서 경로 (run.sh: CA_CERT, 기본 ~/.devoops/rolesanywhere/prod/ca.pem). 개인 키 금지."
  type        = string
}

variable "customer_gateway_ip" {
  description = "온프레 인터넷 공인 IPv4 (pfSense). network.enabled일 때만 필요."
  type        = string
  default     = null
}
