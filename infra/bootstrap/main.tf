terraform {
  required_version = ">= 1.11.0, < 2.0.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}
provider "aws" {
  region              = var.region
  allowed_account_ids = [var.account_id]
  default_tags { tags = { "created by" = "Abu", "for" = "Wiz PSE", Project = var.prefix } }
}
data "aws_partition" "current" {}
locals {
  arn               = "arn:${data.aws_partition.current.partition}"
  account_arn       = "${local.arn}:iam::${var.account_id}"
  bucket_name       = "${var.prefix}-tfstate-${var.account_id}-${var.region}"
  bucket_arn        = "${local.arn}:s3:::${local.bucket_name}"
  environments      = { plan = "terraform-plan", apply = "terraform-apply", app = "app-deploy" }
  oidc_arn          = var.github_oidc_provider_arn != null ? var.github_oidc_provider_arn : aws_iam_openid_connect_provider.github[0].arn
  workload_roles    = [for name in ["eks", "nodes", "mongodb", "config", "load-balancer-controller"] : "${local.account_arn}:role/${var.prefix}-${name}"]
  workload_policies = [for name in ["mongodb-privilege-creep", "load-balancer-controller"] : "${local.account_arn}:policy/${var.prefix}-${name}"]
  managed_policies  = [for name in ["AmazonEKSClusterPolicy", "AmazonEKSWorkerNodePolicy", "AmazonEC2ContainerRegistryPullOnly", "AmazonEKS_CNI_Policy", "service-role/AWS_ConfigRole"] : "${local.arn}:iam::aws:policy/${name}"]
}
resource "aws_iam_openid_connect_provider" "github" {
  count          = var.github_oidc_provider_arn == null ? 1 : 0
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}
resource "aws_iam_role" "ci" {
  for_each             = local.environments
  name                 = "${var.prefix}-ci-${each.key}"
  max_session_duration = 3600
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect    = "Allow", Action = "sts:AssumeRoleWithWebIdentity",
    Principal = { Federated = local.oidc_arn },
    Condition = { StringEquals = {
      "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com",
      "token.actions.githubusercontent.com:sub" = "repo:${var.github_repository}:environment:${each.value}"
    } }
  }] })
}
