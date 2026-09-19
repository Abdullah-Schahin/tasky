# Locals
data "aws_partition" "current" {}
locals {
  tags = {
    "created by" = "Abu"
    "for"        = "Wiz PSE"
    Project      = var.prefix
  }
  azs                = { for i, az in var.availability_zones : tostring(i) => az }
  mongodb_secret_arn = var.mongodb_secret_arn != null ? var.mongodb_secret_arn : aws_secretsmanager_secret.mongodb[0].arn
  aws_prefix         = "arn:${data.aws_partition.current.partition}"
}

# Eks
resource "aws_iam_role" "eks" {
  permissions_boundary = var.workload_permissions_boundary_arn
  name                 = "${var.prefix}-eks"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect = "Allow", Principal = { Service = "eks.amazonaws.com" }, Action = "sts:AssumeRole"
  }] })
}
resource "aws_iam_role_policy_attachment" "eks" {
  role       = aws_iam_role.eks.name
  policy_arn = "${local.aws_prefix}:iam::aws:policy/AmazonEKSClusterPolicy"
}
resource "aws_cloudwatch_log_group" "eks" {
  name              = "/aws/eks/${var.prefix}/cluster"
  retention_in_days = 30
}
resource "aws_eks_cluster" "main" {
  name                      = var.prefix
  role_arn                  = aws_iam_role.eks.arn
  version                   = var.eks_version
  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = false
  }
  vpc_config {
    subnet_ids              = [for s in aws_subnet.private : s.id]
    endpoint_private_access = true
    endpoint_public_access  = length(var.eks_public_access_cidrs) > 0
    public_access_cidrs     = length(var.eks_public_access_cidrs) > 0 ? var.eks_public_access_cidrs : null
  }
  depends_on = [aws_iam_role_policy_attachment.eks, aws_cloudwatch_log_group.eks]
}
resource "aws_eks_access_entry" "operator" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = var.eks_admin_principal_arn
  type          = "STANDARD"
}
resource "aws_eks_access_policy_association" "operator" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_eks_access_entry.operator.principal_arn
  policy_arn    = "${local.aws_prefix}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope { type = "cluster" }
}
resource "aws_iam_role" "nodes" {
  permissions_boundary = var.workload_permissions_boundary_arn
  name                 = "${var.prefix}-nodes"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole"
  }] })
}
resource "aws_iam_role_policy_attachment" "nodes" {
  for_each   = toset(["AmazonEKSWorkerNodePolicy", "AmazonEC2ContainerRegistryPullOnly", "AmazonEKS_CNI_Policy"])
  role       = aws_iam_role.nodes.name
  policy_arn = "${local.aws_prefix}:iam::aws:policy/${each.value}"
}
resource "aws_launch_template" "nodes" {
  name_prefix            = "${var.prefix}-nodes-"
  vpc_security_group_ids = [aws_eks_cluster.main.vpc_config[0].cluster_security_group_id, aws_security_group.nodes.id]
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 30
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }
  dynamic "tag_specifications" {
    for_each = toset(["instance", "volume", "network-interface"])
    content {
      resource_type = tag_specifications.value
      tags          = merge(local.tags, { Name = "${var.prefix}-node" })
    }
  }
}
resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.prefix}-private"
  node_role_arn   = aws_iam_role.nodes.arn
  subnet_ids      = [for s in aws_subnet.private : s.id]
  ami_type        = "AL2023_x86_64_STANDARD"
  instance_types  = [var.node_instance_type]
  capacity_type   = "ON_DEMAND"
  labels          = { "exercise.tasky.io/network" = "private" }
  scaling_config {
    desired_size = 2
    min_size     = 2
    max_size     = 2
  }
  launch_template {
    id      = aws_launch_template.nodes.id
    version = aws_launch_template.nodes.latest_version
  }
  depends_on = [aws_iam_role_policy_attachment.nodes, aws_route.outbound]
}
# EKS creates this group itself, so provider default_tags cannot reach it.
resource "aws_ec2_tag" "eks_group" {
  for_each    = local.tags
  resource_id = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
  key         = each.key
  value       = each.value
}
data "tls_certificate" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}
resource "aws_iam_openid_connect_provider" "eks" {
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
}
resource "aws_iam_role" "load_balancer_controller" {
  permissions_boundary = var.workload_permissions_boundary_arn
  name                 = "${var.prefix}-load-balancer-controller"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect    = "Allow", Action = "sts:AssumeRoleWithWebIdentity",
    Principal = { Federated = aws_iam_openid_connect_provider.eks.arn },
    Condition = { StringEquals = {
      "${trimprefix(aws_iam_openid_connect_provider.eks.url, "https://")}:aud" = "sts.amazonaws.com"
      "${trimprefix(aws_iam_openid_connect_provider.eks.url, "https://")}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
    } }
  }] })
}
resource "aws_iam_policy" "load_balancer_controller" {
  name   = "${var.prefix}-load-balancer-controller"
  policy = file("${path.module}/policies/load-balancer-controller.json")
}
resource "aws_iam_role_policy_attachment" "load_balancer_controller" {
  role       = aws_iam_role.load_balancer_controller.name
  policy_arn = aws_iam_policy.load_balancer_controller.arn
}
resource "aws_autoscaling_group_tag" "nodes" {
  for_each               = local.tags
  autoscaling_group_name = aws_eks_node_group.main.resources[0].autoscaling_groups[0].name
  tag {
    key                 = each.key
    value               = each.value
    propagate_at_launch = true
  }
}

# Keep this in the infrastructure stack: the bootstrap stack has no EKS dependency.
resource "aws_eks_access_entry" "app_deploy" {
  count         = var.app_deploy_role_arn == null ? 0 : 1
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = var.app_deploy_role_arn
  type          = "STANDARD"
}
resource "aws_eks_access_policy_association" "app_deploy" {
  count         = var.app_deploy_role_arn == null ? 0 : 1
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_eks_access_entry.app_deploy[0].principal_arn
  policy_arn    = "${local.aws_prefix}:eks::aws:cluster-access-policy/AmazonEKSAdminPolicy"
  access_scope {
    type       = "namespace"
    namespaces = ["tasky"]
  }
}

# Iam
resource "aws_iam_role" "mongodb" {
  permissions_boundary = var.workload_permissions_boundary_arn
  name                 = "${var.prefix}-mongodb"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole"
  }] })
}
resource "aws_iam_instance_profile" "mongodb" {
  name = "${var.prefix}-mongodb"
  role = aws_iam_role.mongodb.name
}
resource "aws_iam_policy" "mongodb" {
  name = "${var.prefix}-mongodb-privilege-creep"
  # DELIBERATE: host needs only one backup prefix, but inherited fleet permissions
  # permit EC2 lifecycle changes and access to every object in this account's S3.
  # No AdministratorAccess, IAM writes, public bucket writes or PassRole.
  policy = jsonencode({ Version = "2012-10-17", Statement = concat([
    { Sid = "ExcessiveEC2DiscoveryAndLifecycle", Effect = "Allow", Action = ["ec2:Describe*", "ec2:RunInstances", "ec2:StartInstances", "ec2:StopInstances", "ec2:CreateTags"], Resource = "*" },
    { Sid = "ExcessiveS3DataAccess", Effect = "Allow", Action = ["s3:ListBucket", "s3:GetObject", "s3:PutObject", "s3:DeleteObject"], Resource = ["${local.aws_prefix}:s3:::*"], Condition = { StringEquals = { "s3:ResourceAccount" = var.account_id } } },
    { Sid = "ReadDatabaseCredentials", Effect = "Allow", Action = "secretsmanager:GetSecretValue", Resource = local.mongodb_secret_arn }
    ], var.mongodb_secret_kms_key_arn == null ? [] : [
    { Sid = "DecryptDatabaseCredentials", Effect = "Allow", Action = "kms:Decrypt", Resource = var.mongodb_secret_kms_key_arn, Condition = { StringEquals = { "kms:ViaService" = "secretsmanager.${var.region}.amazonaws.com" } } }
  ]) })
}
resource "aws_iam_role_policy_attachment" "mongodb" {
  role       = aws_iam_role.mongodb.name
  policy_arn = aws_iam_policy.mongodb.arn
}

# Ecr
resource "aws_ecr_repository" "tasky" {
  name                 = "${var.prefix}/tasky"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = false
  image_scanning_configuration { scan_on_push = true }
  encryption_configuration { encryption_type = "AES256" }
}
# No lifecycle rule deleting signed release evidence while the demo is being evaluated.

# Secrets
# Passwords flow directly from ephemeral generation to the provider's write-only
# argument. Terraform records metadata/version, not the password material.
ephemeral "random_password" "mongodb" {
  for_each = var.mongodb_secret_arn == null ? toset(["admin_password", "app_password", "backup_password"]) : toset([])
  length   = 32
  special  = false
}
resource "aws_secretsmanager_secret" "mongodb" {
  count                   = var.mongodb_secret_arn == null ? 1 : 0
  name                    = "${var.prefix}/mongodb"
  description             = "MongoDB exercise credentials; fetched at EC2 bootstrap"
  kms_key_id              = var.mongodb_secret_kms_key_arn
  recovery_window_in_days = 7
}
resource "aws_secretsmanager_secret_version" "mongodb" {
  count                    = var.mongodb_secret_arn == null ? 1 : 0
  secret_id                = aws_secretsmanager_secret.mongodb[0].id
  secret_string_wo         = jsonencode({ for k, v in ephemeral.random_password.mongodb : k => v.result })
  secret_string_wo_version = 1
}

# Security
resource "aws_iam_role" "config" {
  permissions_boundary = var.workload_permissions_boundary_arn
  count                = var.enable_config ? 1 : 0
  name                 = "${var.prefix}-config"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect    = "Allow", Principal = { Service = "config.amazonaws.com" }, Action = "sts:AssumeRole",
    Condition = { StringEquals = { "aws:SourceAccount" = var.account_id } }
  }] })
}
resource "aws_iam_role_policy_attachment" "config" {
  count      = var.enable_config ? 1 : 0
  role       = aws_iam_role.config[0].name
  policy_arn = "${local.aws_prefix}:iam::aws:policy/service-role/AWS_ConfigRole"
}
resource "aws_iam_role_policy" "config_delivery" {
  count = var.enable_config ? 1 : 0
  name  = "audit-delivery"
  role  = aws_iam_role.config[0].id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = ["s3:GetBucketAcl", "s3:ListBucket"], Resource = aws_s3_bucket.audit.arn },
    { Effect = "Allow", Action = "s3:PutObject", Resource = "${aws_s3_bucket.audit.arn}/config/AWSLogs/${var.account_id}/Config/*" }
  ] })
}
resource "aws_config_configuration_recorder" "main" {
  count    = var.enable_config ? 1 : 0
  name     = var.prefix
  role_arn = aws_iam_role.config[0].arn
  recording_group {
    all_supported                 = false
    include_global_resource_types = false
    resource_types                = ["AWS::S3::Bucket", "AWS::EC2::SecurityGroup", "AWS::EC2::Instance", "AWS::EKS::Cluster"]
  }
  depends_on = [aws_iam_role_policy_attachment.config, aws_iam_role_policy.config_delivery]
}
resource "aws_config_delivery_channel" "main" {
  count          = var.enable_config ? 1 : 0
  name           = var.prefix
  s3_bucket_name = aws_s3_bucket.audit.id
  s3_key_prefix  = "config"
  depends_on     = [aws_config_configuration_recorder.main, aws_s3_bucket_policy.audit]
}
resource "aws_config_configuration_recorder_status" "main" {
  count      = var.enable_config ? 1 : 0
  name       = aws_config_configuration_recorder.main[0].name
  is_enabled = true
  depends_on = [aws_config_delivery_channel.main]
}
resource "aws_config_config_rule" "exercise" {
  for_each = var.enable_config ? {
    public-s3  = "S3_BUCKET_PUBLIC_READ_PROHIBITED"
    open-ssh   = "INCOMING_SSH_DISABLED"
    versioning = "S3_BUCKET_VERSIONING_ENABLED"
  } : {}
  name = "${var.prefix}-${each.key}"
  source {
    owner             = "AWS"
    source_identifier = each.value
  }
  depends_on = [aws_config_configuration_recorder_status.main]
}
# Regional security services. Import existing enrollments before managing them.
resource "aws_securityhub_account" "main" {
  count                    = var.enable_security_hub ? 1 : 0
  enable_default_standards = true
}
resource "aws_guardduty_detector" "main" {
  count  = var.enable_guardduty ? 1 : 0
  enable = true
}

# Logging
# Shared private audit destination for Config and, only if needed, CloudTrail.
resource "aws_s3_bucket" "audit" {
  bucket        = "${var.prefix}-audit-${var.account_id}-${var.region}"
  force_destroy = false
}
resource "aws_s3_bucket_ownership_controls" "audit" {
  bucket = aws_s3_bucket.audit.id
  rule { object_ownership = "BucketOwnerEnforced" }
}
resource "aws_s3_bucket_public_access_block" "audit" {
  bucket                  = aws_s3_bucket.audit.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}
resource "aws_s3_bucket_versioning" "audit" {
  bucket = aws_s3_bucket.audit.id
  versioning_configuration { status = "Enabled" }
}
resource "aws_s3_bucket_server_side_encryption_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}
resource "aws_s3_bucket_policy" "audit" {
  bucket = aws_s3_bucket.audit.id
  policy = jsonencode({ Version = "2012-10-17", Statement = concat([
    # PREVENTIVE CONTROL: secure audit resources reject HTTP, with no exception
    # for the vulnerable backup bucket. This policy is enforced by AWS on requests.
    { Sid = "DenyInsecureTransport", Effect = "Deny", Principal = "*", Action = "s3:*", Resource = [aws_s3_bucket.audit.arn, "${aws_s3_bucket.audit.arn}/*"], Condition = { Bool = { "aws:SecureTransport" = "false" } } }
    ], var.existing_cloudtrail_arn != null ? [] : [
    { Sid = "TrailACL", Effect = "Allow", Principal = { Service = "cloudtrail.amazonaws.com" }, Action = "s3:GetBucketAcl", Resource = aws_s3_bucket.audit.arn, Condition = { StringEquals = { "aws:SourceArn" = "${local.aws_prefix}:cloudtrail:${var.region}:${var.account_id}:trail/${var.prefix}" } } },
    { Sid = "TrailWrite", Effect = "Allow", Principal = { Service = "cloudtrail.amazonaws.com" }, Action = "s3:PutObject", Resource = "${aws_s3_bucket.audit.arn}/cloudtrail/AWSLogs/${var.account_id}/*", Condition = { StringEquals = { "aws:SourceArn" = "${local.aws_prefix}:cloudtrail:${var.region}:${var.account_id}:trail/${var.prefix}", "s3:x-amz-acl" = "bucket-owner-full-control" } } }
    ], !var.enable_config ? [] : [
    { Sid = "ConfigReadMetadata", Effect = "Allow", Principal = { Service = "config.amazonaws.com" }, Action = ["s3:GetBucketAcl", "s3:ListBucket"], Resource = aws_s3_bucket.audit.arn, Condition = { StringEquals = { "aws:SourceAccount" = var.account_id } } },
    { Sid = "ConfigWrite", Effect = "Allow", Principal = { Service = "config.amazonaws.com" }, Action = ["s3:PutObject"], Resource = "${aws_s3_bucket.audit.arn}/config/AWSLogs/${var.account_id}/Config/*", Condition = { StringEquals = { "aws:SourceAccount" = var.account_id, "s3:x-amz-acl" = "bucket-owner-full-control" } } }
  ]) })
}
resource "aws_cloudtrail" "main" {
  count                         = var.existing_cloudtrail_arn == null ? 1 : 0
  name                          = var.prefix
  s3_bucket_name                = aws_s3_bucket.audit.id
  s3_key_prefix                 = "cloudtrail"
  is_multi_region_trail         = true
  include_global_service_events = true
  enable_log_file_validation    = true
  enable_logging                = true
  event_selector {
    read_write_type           = "All"
    include_management_events = true
  }
  depends_on = [aws_s3_bucket_policy.audit]
}

# FreeDNS owns public DNS. Output the validation CNAME for the operator instead
# of waiting here; the app deployment explicitly requires an ISSUED certificate.
resource "aws_acm_certificate" "app" {
  domain_name       = "tasky-abu-pse.apps.dj"
  validation_method = "DNS"
  lifecycle { create_before_destroy = true }
}
