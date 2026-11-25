output "vpc_id" {
  value = aws_vpc.this.id
}

output "public_subnet_ids" {
  description = "AZ => 퍼블릭 서브넷 ID."
  value       = { for az, subnet in aws_subnet.public : az => subnet.id }
}

output "private_subnet_ids" {
  description = "AZ => 프라이빗 서브넷 ID."
  value       = { for az, subnet in aws_subnet.private : az => subnet.id }
}

output "vpn_connection_id" {
  value = aws_vpn_connection.this.id
}

output "vpn_sync_revision" {
  description = "VPN의 터널 구성 변경 감지용 해시. PSK 원문은 외부 실행기로 넘기지 않는다."
  value       = sha256(aws_vpn_connection.this.customer_gateway_configuration)
  sensitive   = true
}
