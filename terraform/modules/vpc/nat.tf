locals {
  nat_az = sort(keys(var.subnets))[0]
}

# NAT Gateway가 인터넷 통신에 사용할 공인 IP
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${var.name_prefix}-nat-eip"
  }
}

# 첫 AZ(EKS A의 노드와 같은 AZ)에 NAT 하나. 모든 프라이빗 서브넷이 공유한다
resource "aws_nat_gateway" "this" {
  allocation_id     = aws_eip.nat.id
  subnet_id         = aws_subnet.public[local.nat_az].id
  connectivity_type = "public"

  depends_on = [aws_internet_gateway.this]

  tags = {
    Name = "${var.name_prefix}-nat-${local.nat_az}"
  }
}
