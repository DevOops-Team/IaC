# AWS 쪽 VPN 게이트웨이
resource "aws_vpn_gateway" "this" {
  vpc_id          = aws_vpc.this.id
  amazon_side_asn = var.amazon_side_asn

  tags = {
    Name = "${local.name_prefix}-vgw"
  }
}

# 온프레 pfSense의 공인 IP·BGP ASN 등록
resource "aws_customer_gateway" "this" {
  bgp_asn    = var.customer_gateway_asn
  ip_address = var.customer_gateway_ip
  type       = "ipsec.1"

  tags = {
    Name = "${local.name_prefix}-cgw"
  }
}

# VPN 연결 1개에 터널 2개 포함
resource "aws_vpn_connection" "this" {
  vpn_gateway_id      = aws_vpn_gateway.this.id
  customer_gateway_id = aws_customer_gateway.this.id
  type                = "ipsec.1"
  static_routes_only  = false

  local_ipv4_network_cidr  = "0.0.0.0/0"
  remote_ipv4_network_cidr = "0.0.0.0/0"

  # Tunnel 1
  tunnel1_ike_versions                 = ["ikev2"]
  tunnel1_phase1_encryption_algorithms = ["AES256"]
  tunnel1_phase1_integrity_algorithms  = ["SHA2-256"]
  tunnel1_phase1_dh_group_numbers      = [14]
  tunnel1_phase1_lifetime_seconds      = 28800

  tunnel1_phase2_encryption_algorithms = ["AES256"]
  tunnel1_phase2_integrity_algorithms  = ["SHA2-256"]
  tunnel1_phase2_dh_group_numbers      = [14]
  tunnel1_phase2_lifetime_seconds      = 3600

  # Tunnel 2
  tunnel2_ike_versions                 = ["ikev2"]
  tunnel2_phase1_encryption_algorithms = ["AES256"]
  tunnel2_phase1_integrity_algorithms  = ["SHA2-256"]
  tunnel2_phase1_dh_group_numbers      = [14]
  tunnel2_phase1_lifetime_seconds      = 28800

  tunnel2_phase2_encryption_algorithms = ["AES256"]
  tunnel2_phase2_integrity_algorithms  = ["SHA2-256"]
  tunnel2_phase2_dh_group_numbers      = [14]
  tunnel2_phase2_lifetime_seconds      = 3600

  tags = {
    Name = "${local.name_prefix}-vpn"
  }
}

# BGP로 학습한 경로를 프라이빗 라우팅 테이블 3곳에 전파
resource "aws_vpn_gateway_route_propagation" "private" {
  for_each = var.subnets

  vpn_gateway_id = aws_vpn_gateway.this.id
  route_table_id = aws_route_table.private[each.key].id
}
