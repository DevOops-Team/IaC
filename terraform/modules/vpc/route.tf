# 퍼블릭 서브넷이 공유하는 라우팅 테이블 → IGW
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-public-rt"
  }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  for_each = var.subnets

  subnet_id      = aws_subnet.public[each.key].id
  route_table_id = aws_route_table.public.id
}

# 프라이빗 라우팅 테이블은 AZ마다 (나중에 AZ별 NAT로 늘릴 수 있게) → NAT
resource "aws_route_table" "private" {
  for_each = var.subnets

  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-private-rt-${each.key}"
  }
}

resource "aws_route" "private_internet" {
  for_each = var.subnets

  route_table_id         = aws_route_table.private[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this.id
}

resource "aws_route_table_association" "private" {
  for_each = var.subnets

  subnet_id      = aws_subnet.private[each.key].id
  route_table_id = aws_route_table.private[each.key].id
}
