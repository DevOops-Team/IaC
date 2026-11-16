# 레포에 두지 않는 값. run.sh가 넘기거나 terraform.local.tfvars에 둔다.
variable "ca_certificate_path" {
  description = "처음 trust anchor(primary)의 CA 공개 인증서 경로. 바꾸면 그 anchor의 CA가 바뀌어 기존 인증서가 끊긴다. 개인 키 금지."
  type        = string
}

variable "additional_ca_certificate_paths" {
  description = "추가로 믿을 CA 이름 => 공개 인증서 경로 (예: v2 = ~/.devoops/rolesanywhere/prod/ca.pem). 이름마다 trust anchor가 하나 생긴다."
  type        = map(string)
  default     = {}
}

variable "customer_gateway_ip" {
  description = "온프레 pfSense 공인 IPv4 (VPN 상대 주소). network.enabled일 때만 필요."
  type        = string
  default     = null
}
