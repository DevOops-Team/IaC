# VPC 일체 (modules/vpc). config network.enabled: false면 만들지 않는다 (NAT · VPN 과금).
module "vpc" {
  source = "../../modules/vpc"
  count  = local.cfg.network.enabled ? 1 : 0

  name_prefix = local.name_prefix
  cidr        = local.cfg.network.cidr
  subnets     = local.cfg.network.subnets
  vpn = {
    customer_gateway_ip  = var.customer_gateway_ip
    customer_gateway_asn = local.cfg.network.vpn.customer_gateway_asn
    amazon_side_asn      = local.cfg.network.vpn.amazon_side_asn
  }
}
