# 레포에 두지 않는 값. run.sh가 넘기거나 terraform.local.tfvars에 둔다.
variable "ca_certificate_path" {
  description = "Roles Anywhere CA 공개 인증서 경로 (기본 ~/.devoops/rolesanywhere/prod/ca.pem). 개인 키 금지."
  type        = string
}

variable "customer_gateway_ip" {
  description = "온프레 pfSense 공인 IPv4 (VPN 상대 주소). network.enabled일 때만 필요."
  type        = string
  default     = null
}
