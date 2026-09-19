# Dedicated deployment host; no public address, inbound rules or SSH key.
data "aws_ami" "runner" {
  most_recent = true
  owners      = ["099720109477"]
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}
resource "aws_security_group" "runner" {
  name_prefix = "${var.prefix}-runner-"
  description = "Private deployment runner; no inbound access"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${var.prefix}-runner" }
}
resource "aws_vpc_security_group_egress_rule" "runner" {
  for_each          = toset(["80", "443"])
  security_group_id = aws_security_group.runner.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = tonumber(each.value)
  to_port           = tonumber(each.value)
}
resource "aws_vpc_security_group_ingress_rule" "runner_eks" {
  security_group_id            = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
  referenced_security_group_id = aws_security_group.runner.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  description                  = "Deployment runner to private Kubernetes API"
}
resource "aws_iam_role" "runner" {
  name                 = "${var.prefix}-runner"
  permissions_boundary = var.workload_permissions_boundary_arn
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole"
  }] })
}
resource "aws_iam_role_policy_attachment" "runner" {
  role       = aws_iam_role.runner.name
  policy_arn = "${local.aws_prefix}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
resource "aws_iam_instance_profile" "runner" {
  name = "${var.prefix}-runner"
  role = aws_iam_role.runner.name
}
resource "aws_instance" "runner" {
  ami                         = data.aws_ami.runner.id
  instance_type               = "t3.medium"
  subnet_id                   = aws_subnet.private["0"].id
  associate_public_ip_address = false
  vpc_security_group_ids      = [aws_security_group.runner.id]
  iam_instance_profile        = aws_iam_instance_profile.runner.name
  user_data_replace_on_change = true
  user_data                   = file("${path.module}/templates/runner.sh")
  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1
  }
  root_block_device {
    encrypted   = true
    volume_type = "gp3"
    volume_size = 30
    tags        = local.tags
  }
  tags = { Name = "${var.prefix}-runner" }
  depends_on = [aws_route.outbound, aws_route_table_association.private,
  aws_vpc_security_group_egress_rule.runner, aws_iam_role_policy_attachment.runner]
}
output "runner_instance_id" { value = aws_instance.runner.id }
