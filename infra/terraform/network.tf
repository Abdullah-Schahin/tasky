resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = var.prefix }
}
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = var.prefix }
}
resource "aws_subnet" "public" {
  for_each                = local.azs
  vpc_id                  = aws_vpc.main.id
  availability_zone       = each.value
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, tonumber(each.key))
  map_public_ip_on_launch = false
  tags = {
    Name                     = "${var.prefix}-public-${each.key}"
    "kubernetes.io/role/elb" = "1"
  }
}
resource "aws_subnet" "private" {
  for_each                = local.azs
  vpc_id                  = aws_vpc.main.id
  availability_zone       = each.value
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, 10 + tonumber(each.key))
  map_public_ip_on_launch = false
  tags = {
    Name                              = "${var.prefix}-private-${each.key}"
    "kubernetes.io/role/internal-elb" = "1"
  }
}
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.prefix}-public" }
}
resource "aws_route" "internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}
resource "aws_route_table_association" "public" {
  for_each       = local.azs
  subnet_id      = aws_subnet.public[each.key].id
  route_table_id = aws_route_table.public.id
}
# One NAT for the short-lived lab. No extra NAT instances or VPC endpoints.
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.prefix}-nat" }
}
resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public["0"].id
  depends_on    = [aws_internet_gateway.main]
  tags          = { Name = "${var.prefix}-nat" }
}
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.prefix}-private" }
}
resource "aws_route" "outbound" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main.id
}
resource "aws_route_table_association" "private" {
  for_each       = local.azs
  subnet_id      = aws_subnet.private[each.key].id
  route_table_id = aws_route_table.private.id
}
# DELIBERATE: no VPC Flow Logs for the exercise.
resource "aws_security_group" "nodes" {
  name_prefix = "${var.prefix}-nodes-"
  description = "Additional node identity for restricted MongoDB ingress"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${var.prefix}-nodes" }
}
