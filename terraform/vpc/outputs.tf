# eks root가 terraform_remote_state로 읽는다 (eks/vpc.tf). 이름을 바꾸면 eks도 같이 바꾼다.
output "vpc_id" {
  description = "ID of the project VPC."
  value       = aws_vpc.this.id
}

output "public_subnet_ids" {
  description = "Public subnet IDs keyed by Availability Zone."
  value       = { for az, subnet in aws_subnet.public : az => subnet.id }
}

output "private_subnet_ids" {
  description = "Private subnet IDs keyed by Availability Zone."
  value       = { for az, subnet in aws_subnet.private : az => subnet.id }
}

output "vpn_connection_id" {
  description = "Site-to-site VPN to the on-prem pfSense."
  value       = aws_vpn_connection.this.id
}
