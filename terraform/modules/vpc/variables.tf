variable "name_prefix" {
  description = "Prefix for Name tags (e.g. devoops-prod)."
  type        = string
}

variable "cidr" {
  description = "VPC IPv4 CIDR."
  type        = string
}

variable "subnets" {
  description = "AZ => public/private subnet CIDR. NAT goes to the first AZ (sorted)."
  type = map(object({
    public_cidr  = string
    private_cidr = string
  }))
}

variable "vpn" {
  description = "Site-to-site VPN to on-prem pfSense (BGP)."
  type = object({
    customer_gateway_ip  = string
    customer_gateway_asn = number
    amazon_side_asn      = number
  })
  validation {
    condition     = can(cidrnetmask("${var.vpn.customer_gateway_ip}/32"))
    error_message = "customer_gateway_ip must be a valid IPv4 address."
  }
}
