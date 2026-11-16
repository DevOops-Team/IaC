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
