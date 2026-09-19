data "aws_ami" "mongodb" {
  owners = ["099720109477"] # Canonical; never select an untrusted AMI by name alone.
  filter {
    name   = "image-id"
    values = [var.mongodb_ami_id]
  }
  include_deprecated = true
}
resource "aws_key_pair" "mongodb" {
  key_name_prefix = "${var.prefix}-mongodb-"
  public_key      = var.ssh_public_key
}
resource "aws_security_group" "mongodb" {
  name_prefix = "${var.prefix}-mongodb-"
  description = "Exercise public SSH; MongoDB only from private EKS nodes"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${var.prefix}-mongodb" }
}
resource "aws_vpc_security_group_ingress_rule" "ssh" {
  security_group_id = aws_security_group.mongodb.id
  description       = "DELIBERATE public SSH; key-only authentication"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
}
resource "aws_vpc_security_group_ingress_rule" "mongodb" {
  security_group_id            = aws_security_group.mongodb.id
  description                  = "Private EKS workload path only, MongoDB requires TLS and authentication"
  referenced_security_group_id = aws_security_group.nodes.id
  ip_protocol                  = "tcp"
  from_port                    = 27017
  to_port                      = 27017
}
resource "aws_vpc_security_group_egress_rule" "mongodb_packages" {
  for_each          = toset(["80", "443"])
  security_group_id = aws_security_group.mongodb.id
  description       = "Package repositories and HTTPS AWS APIs"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = tonumber(each.value)
  to_port           = tonumber(each.value)
}
resource "aws_instance" "mongodb" {
  ami                         = data.aws_ami.mongodb.id
  instance_type               = var.mongodb_instance_type
  subnet_id                   = aws_subnet.public["0"].id
  private_ip                  = cidrhost(aws_subnet.public["0"].cidr_block, 10)
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.mongodb.id]
  key_name                    = aws_key_pair.mongodb.key_name
  iam_instance_profile        = aws_iam_instance_profile.mongodb.name
  user_data_replace_on_change = true
  user_data = templatefile("${path.module}/templates/mongodb.sh.tftpl", {
    region        = var.region
    secret_arn    = local.mongodb_secret_arn
    bucket        = aws_s3_bucket.backup.id
    private_ip    = cidrhost(aws_subnet.public["0"].cidr_block, 10)
    codename      = var.mongodb_ubuntu_codename
    mongo_version = "6.0.16" # Released in 2024; intentionally unsupported/outdated for the exercise.
  })
  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1
  }
  root_block_device {
    encrypted             = true
    volume_type           = "gp3"
    volume_size           = 30
    delete_on_termination = true
    tags                  = local.tags
  }
  tags = { Name = "${var.prefix}-mongodb", "exercise:outdated" = "true" }
  lifecycle {
    precondition {
      condition     = timecmp(data.aws_ami.mongodb.creation_date, timeadd(plantimestamp(), "-8760h")) < 0
      error_message = "The exercise AMI must be more than one year old."
    }
    precondition {
      condition     = data.aws_ami.mongodb.architecture == "x86_64" && strcontains(data.aws_ami.mongodb.name, "ubuntu-${var.mongodb_ubuntu_codename}-")
      error_message = "Use an official Ubuntu amd64 AMI matching mongodb_ubuntu_codename."
    }
  }
  depends_on = [aws_secretsmanager_secret_version.mongodb, aws_iam_role_policy_attachment.mongodb, aws_route.internet, aws_s3_bucket_policy.backup]
}
