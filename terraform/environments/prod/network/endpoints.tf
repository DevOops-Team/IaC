data "aws_region" "current" {}

# AWS adds a service prefix-list route to each selected private route table.
resource "aws_vpc_endpoint" "storage" {
  for_each = toset(["s3", "dynamodb"])

  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.${each.key}"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [for route_table in aws_route_table.private : route_table.id]

  tags = {
    Name = "${local.name_prefix}-${each.key}-vpce"
  }
}
