variable "name_prefix" {
  description = "Name 태그 접두어 (예: devoops-prod)."
  type        = string
}

variable "cidr" {
  description = "VPC IPv4 CIDR."
  type        = string
}

variable "subnets" {
  description = "AZ => 퍼블릭 · 프라이빗 서브넷 CIDR. NAT는 정렬한 첫 AZ에 둔다."
  type = map(object({
    public_cidr  = string
    private_cidr = string
  }))
}

variable "vpn" {
  description = "온프레 pfSense와의 Site-to-Site VPN (BGP). customer_gateway_ip는 온프레 공인 IP."
  type = object({
    customer_gateway_ip  = string
    customer_gateway_asn = number
    amazon_side_asn      = number
  })
  validation {
    condition     = can(cidrnetmask("${var.vpn.customer_gateway_ip}/32"))
    error_message = "customer_gateway_ip는 올바른 IPv4 주소여야 한다."
  }
}
