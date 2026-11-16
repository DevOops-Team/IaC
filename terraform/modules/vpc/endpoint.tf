data "aws_region" "current" {}

# S3 · DynamoDB Gateway 엔드포인트: 프라이빗 라우팅 테이블에 경로가 붙어 NAT를 거치지 않는다
resource "aws_vpc_endpoint" "storage" {
  for_each = toset(["s3", "dynamodb"])

  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.${each.key}"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [for route_table in aws_route_table.private : route_table.id]

  tags = {
    Name = "${var.name_prefix}-${each.key}-vpce"
  }
}
