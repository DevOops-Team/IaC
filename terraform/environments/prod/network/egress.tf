# Internet Gateway: VPC와 인터넷을 연결
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${local.name_prefix}-igw"
  }
}

# NAT Gateway가 인터넷 통신에 사용할 공인 IP
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${local.name_prefix}-nat-eip"
  }
}

# 첫 워커와 같은 AZ에 NAT Gateway 배치
resource "aws_nat_gateway" "this" {
  allocation_id     = aws_eip.nat.id
  subnet_id         = aws_subnet.public["us-east-2a"].id
  connectivity_type = "public"

  depends_on = [aws_internet_gateway.this]

  tags = {
    Name = "${local.name_prefix}-nat-us-east-2a"
  }
}

# 퍼블릭 서브넷 3곳이 공유할 라우팅 테이블
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${local.name_prefix}-public-rt"
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

# 향후 AZ별 NAT 확장을 위해 프라이빗 라우팅 테이블은 분리
resource "aws_route_table" "private" {
  for_each = var.subnets

  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${local.name_prefix}-private-rt-${each.key}"
  }
}

# 현재는 모든 프라이빗 서브넷이 NAT 1개를 공유
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
