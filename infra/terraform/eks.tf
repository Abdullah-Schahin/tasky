resource "aws_iam_role" "eks" {
  name = "${var.prefix}-eks"
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
  name = "${var.prefix}-nodes"
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
  name = "${var.prefix}-load-balancer-controller"
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
