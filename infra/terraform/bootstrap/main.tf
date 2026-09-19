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
  arn                   = "arn:${data.aws_partition.current.partition}"
  account_arn           = "${local.arn}:iam::${var.account_id}"
  bucket_name           = "${var.prefix}-tfstate-${var.account_id}-${var.region}"
  bucket_arn            = "${local.arn}:s3:::${local.bucket_name}"
  github_subject_prefix = "repo:${split("/", var.github_repository)[0]}@${var.github_repository_owner_id}/${split("/", var.github_repository)[1]}@${var.github_repository_id}"
  environments          = { plan = "infra-deplyoment", apply = "infra-deplyoment", app = "app-deployment", cluster = "infra-deplyoment" }
  oidc_arn              = var.AWS_GITHUB_OIDC_PROVIDER_ARN != null ? var.AWS_GITHUB_OIDC_PROVIDER_ARN : aws_iam_openid_connect_provider.github[0].arn
  workload_roles        = [for name in ["eks", "nodes", "mongodb", "config", "load-balancer-controller", "runner"] : "${local.account_arn}:role/${var.prefix}-${name}"]
  workload_policies     = [for name in ["mongodb-privilege-creep", "load-balancer-controller"] : "${local.account_arn}:policy/${var.prefix}-${name}"]
  managed_policies      = [for name in ["AmazonEKSClusterPolicy", "AmazonEKSWorkerNodePolicy", "AmazonEC2ContainerRegistryPullOnly", "AmazonEKS_CNI_Policy", "service-role/AWS_ConfigRole", "AmazonSSMManagedInstanceCore"] : "${local.arn}:iam::aws:policy/${name}"]
}
resource "aws_iam_openid_connect_provider" "github" {
  count          = var.AWS_GITHUB_OIDC_PROVIDER_ARN == null ? 1 : 0
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
      "token.actions.githubusercontent.com:sub" = each.key == "plan" ? "${local.github_subject_prefix}:ref:refs/heads/main" : "${local.github_subject_prefix}:environment:${each.value}"
    } }
  }] })
}

resource "aws_s3_bucket" "state" {
  tags          = { BootstrapState = "true" }
  bucket        = local.bucket_name
  force_destroy = false
  lifecycle { prevent_destroy = true }
}
resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}
resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id
  rule { object_ownership = "BucketOwnerEnforced" }
}
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration { status = "Enabled" }
}
resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}
resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Sid = "RequireTLS", Effect = "Deny", Principal = "*", Action = "s3:*", Resource = [local.bucket_arn, "${local.bucket_arn}/*"], Condition = { Bool = { "aws:SecureTransport" = "false" } } },
    { Sid = "ExcludeExerciseWorkloads", Effect = "Deny", Principal = "*", Action = "s3:*", Resource = [local.bucket_arn, "${local.bucket_arn}/*"], Condition = { ArnEquals = { "aws:PrincipalArn" = local.workload_roles } } },
    { Sid = "DenyAppPrivilegedState", Effect = "Deny", Principal = "*", Action = "s3:*", Resource = [for path in ["bootstrap/*", "domain-registration/*", "domain-tls/*", "infra/*", "plans/*"] : "${local.bucket_arn}/${path}"], Condition = { ArnEquals = { "aws:PrincipalArn" = aws_iam_role.ci["app"].arn } } }
  ] })
}
resource "aws_iam_role_policy" "state" {
  for_each = toset(["plan", "apply"])
  name     = "terraform-state"
  role     = aws_iam_role.ci[each.key].id
  policy = jsonencode({ Version = "2012-10-17", Statement = concat([
    { Effect = "Allow", Action = ["s3:ListBucket", "s3:GetBucketLocation", "s3:GetBucketPublicAccessBlock", "s3:GetBucketVersioning", "s3:GetEncryptionConfiguration"], Resource = local.bucket_arn },
    { Effect = "Allow", Action = ["s3:GetObject"], Resource = "${local.bucket_arn}/${var.state_key}" },
    { Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"], Resource = "${local.bucket_arn}/${var.state_key}.tflock" },
    { Effect = "Allow", Action = each.key == "plan" ? ["s3:GetObject", "s3:PutObject"] : ["s3:GetObject"], Resource = "${local.bucket_arn}/plans/*" }
  ], each.key == "apply" ? [{ Effect = "Allow", Action = ["s3:PutObject"], Resource = "${local.bucket_arn}/${var.state_key}" }] : []) })
}

# Discovery metadata only: no general S3 object reads or database secret values.
resource "aws_iam_policy" "discovery" {
  name = "${var.prefix}-ci-discovery"
  policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect = "Allow", Resource = "*", Action = [
      "acm:DescribeCertificate", "acm:ListTagsForCertificate",
      "ec2:Describe*", "eks:Describe*", "eks:List*", "autoscaling:Describe*",
      "iam:GetRole", "iam:GetRolePolicy", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies", "iam:ListInstanceProfilesForRole",
      "iam:GetPolicy", "iam:GetPolicyVersion", "iam:ListPolicyVersions", "iam:GetInstanceProfile",
      "iam:GetOpenIDConnectProvider", "iam:ListOpenIDConnectProviders",
      "logs:Describe*", "logs:ListTagsForResource", "logs:ListTagsLogGroup",
      "s3:GetBucket*", "s3:GetEncryptionConfiguration", "s3:GetLifecycleConfiguration", "s3:GetReplicationConfiguration", "s3:GetAccelerateConfiguration", "s3:ListAllMyBuckets",
      "ecr:Describe*", "ecr:GetRepositoryPolicy", "ecr:GetLifecyclePolicy", "ecr:ListTagsForResource",
      "secretsmanager:DescribeSecret", "secretsmanager:GetResourcePolicy", "secretsmanager:ListSecretVersionIds",
      "config:Describe*", "config:ListTagsForResource", "cloudtrail:DescribeTrails", "cloudtrail:GetTrail*", "cloudtrail:GetEventSelectors", "cloudtrail:ListTags",
      "guardduty:GetDetector", "guardduty:ListDetectors", "guardduty:ListTagsForResource", "securityhub:DescribeHub", "securityhub:ListTagsForResource", "securityhub:GetEnabledStandards"
    ]
    }, {
    # HeadBucket requires ListBucket even when Terraform never reads objects.
    Effect   = "Allow", Action = ["s3:ListBucket"],
    Resource = [for kind in ["audit", "backup"] : "${local.arn}:s3:::${var.prefix}-${kind}-${var.account_id}-${var.region}"]
  }] })
}
resource "aws_iam_role_policy_attachment" "discovery" {
  for_each   = toset(["plan", "apply"])
  role       = aws_iam_role.ci[each.key].name
  policy_arn = aws_iam_policy.discovery.arn
}
# Ceiling, not a grant: workload identity policies still determine actual permissions.
# Prevent an apply job granting a workload IAM administration or state access.
resource "aws_iam_policy" "workload_boundary" {
  name = "${var.prefix}-workload-boundary"
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", NotAction = ["iam:*", "sts:AssumeRole*", "organizations:*", "account:*"], Resource = "*" },
    { Effect = "Allow", Action = "iam:CreateServiceLinkedRole", Resource = "*", Condition = { StringEquals = { "iam:AWSServiceName" = "elasticloadbalancing.amazonaws.com" } } },
    { Effect = "Allow", Action = ["iam:ListServerCertificates", "iam:GetServerCertificate"], Resource = "*" },
    { Effect = "Deny", Action = "s3:*", Resource = [local.bucket_arn, "${local.bucket_arn}/*"] }
  ] })
}
resource "aws_iam_role_policy" "apply_iam" {
  name = "manage-exercise-identities"
  role = aws_iam_role.ci["apply"].id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = ["iam:CreateRole", "iam:PutRolePermissionsBoundary"], Resource = local.workload_roles, Condition = { StringEquals = { "iam:PermissionsBoundary" = aws_iam_policy.workload_boundary.arn } } },
    { Effect = "Allow", Action = ["iam:DeleteRole", "iam:UpdateAssumeRolePolicy", "iam:UpdateRole", "iam:TagRole", "iam:UntagRole", "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:DetachRolePolicy"], Resource = local.workload_roles },
    { Effect = "Allow", Action = "iam:AttachRolePolicy", Resource = local.workload_roles, Condition = { ArnEquals = { "iam:PolicyARN" = concat(local.workload_policies, local.managed_policies) } } },
    { Effect = "Allow", Action = ["iam:CreatePolicy", "iam:DeletePolicy", "iam:CreatePolicyVersion", "iam:DeletePolicyVersion", "iam:SetDefaultPolicyVersion", "iam:TagPolicy", "iam:UntagPolicy"], Resource = local.workload_policies },
    { Effect = "Allow", Action = ["iam:CreateInstanceProfile", "iam:DeleteInstanceProfile", "iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile", "iam:TagInstanceProfile", "iam:UntagInstanceProfile"], Resource = [for name in ["mongodb", "runner"] : "${local.account_arn}:instance-profile/${var.prefix}-${name}"] },
    { Effect = "Allow", Action = "iam:PassRole", Resource = local.workload_roles, Condition = { StringEquals = { "iam:PassedToService" = ["ec2.amazonaws.com", "eks.amazonaws.com", "config.amazonaws.com"] } } },
    { Effect = "Allow", Action = ["iam:CreateOpenIDConnectProvider", "iam:DeleteOpenIDConnectProvider", "iam:UpdateOpenIDConnectProviderThumbprint", "iam:AddClientIDToOpenIDConnectProvider", "iam:RemoveClientIDFromOpenIDConnectProvider", "iam:TagOpenIDConnectProvider", "iam:UntagOpenIDConnectProvider"], Resource = "${local.account_arn}:oidc-provider/oidc.eks.${var.region}.amazonaws.com/id/*" },
    { Effect = "Allow", Action = "iam:CreateServiceLinkedRole", Resource = "${local.account_arn}:role/aws-service-role/*", Condition = { StringEquals = { "iam:AWSServiceName" = ["eks.amazonaws.com", "eks-nodegroup.amazonaws.com", "autoscaling.amazonaws.com", "elasticloadbalancing.amazonaws.com", "guardduty.amazonaws.com", "securityhub.amazonaws.com"] } } }
  ] })
}
# Network APIs include create operations without resource-level restrictions.
# This is a privileged, protected-environment deployment role for a dedicated sandbox.
resource "aws_iam_role_policy" "apply_services" {
  name = "manage-exercise-services"
  role = aws_iam_role.ci["apply"].id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = [
      "ec2:CreateVpc", "ec2:DeleteVpc", "ec2:ModifyVpcAttribute", "ec2:CreateSubnet", "ec2:DeleteSubnet", "ec2:ModifySubnetAttribute",
      "ec2:CreateInternetGateway", "ec2:DeleteInternetGateway", "ec2:AttachInternetGateway", "ec2:DetachInternetGateway",
      "ec2:AllocateAddress", "ec2:ReleaseAddress", "ec2:CreateNatGateway", "ec2:DeleteNatGateway",
      "ec2:CreateRouteTable", "ec2:DeleteRouteTable", "ec2:AssociateRouteTable", "ec2:DisassociateRouteTable", "ec2:ReplaceRouteTableAssociation",
      "ec2:CreateRoute", "ec2:DeleteRoute", "ec2:ReplaceRoute", "ec2:CreateSecurityGroup", "ec2:DeleteSecurityGroup",
      "ec2:AuthorizeSecurityGroupIngress", "ec2:AuthorizeSecurityGroupEgress", "ec2:RevokeSecurityGroupIngress", "ec2:RevokeSecurityGroupEgress", "ec2:ModifySecurityGroupRules",
      "ec2:ImportKeyPair", "ec2:DeleteKeyPair", "ec2:RunInstances", "ec2:TerminateInstances", "ec2:StartInstances", "ec2:StopInstances", "ec2:ModifyInstanceAttribute",
      "ec2:CreateLaunchTemplate", "ec2:DeleteLaunchTemplate", "ec2:CreateLaunchTemplateVersion", "ec2:DeleteLaunchTemplateVersions", "ec2:ModifyLaunchTemplate", "ec2:CreateTags", "ec2:DeleteTags",
      "autoscaling:CreateOrUpdateTags", "autoscaling:DeleteTags",
      "config:PutConfigurationRecorder", "config:DeleteConfigurationRecorder", "config:StartConfigurationRecorder", "config:StopConfigurationRecorder", "config:PutDeliveryChannel", "config:DeleteDeliveryChannel", "config:PutConfigRule", "config:DeleteConfigRule", "config:TagResource", "config:UntagResource",
      "guardduty:CreateDetector", "guardduty:UpdateDetector", "guardduty:DeleteDetector", "guardduty:TagResource", "guardduty:UntagResource",
      "securityhub:EnableSecurityHub", "securityhub:DisableSecurityHub", "securityhub:UpdateSecurityHubConfiguration", "securityhub:TagResource", "securityhub:UntagResource"
    ], Resource = "*", Condition = { StringEquals = { "aws:RequestedRegion" = var.region } } },
    { Effect = "Allow", Action = ["acm:DeleteCertificate"], Resource = "${local.arn}:acm:${var.region}:${var.account_id}:certificate/*" },
    { Effect = "Allow", Action = "eks:*", Resource = ["${local.arn}:eks:${var.region}:${var.account_id}:cluster/${var.prefix}", "${local.arn}:eks:${var.region}:${var.account_id}:nodegroup/${var.prefix}/*", "${local.arn}:eks:${var.region}:${var.account_id}:access-entry/${var.prefix}/*", "${local.arn}:eks:${var.region}:${var.account_id}:addon/${var.prefix}/*"] },
    { Effect = "Allow", Action = "ecr:*", Resource = "${local.arn}:ecr:${var.region}:${var.account_id}:repository/${var.prefix}/tasky" },
    { Effect = "Allow", Action = "logs:*", Resource = ["${local.arn}:logs:${var.region}:${var.account_id}:log-group:/aws/eks/${var.prefix}/cluster", "${local.arn}:logs:${var.region}:${var.account_id}:log-group:/aws/eks/${var.prefix}/cluster:*"] },
    { Effect = "Allow", Action = "cloudtrail:*", Resource = "${local.arn}:cloudtrail:${var.region}:${var.account_id}:trail/${var.prefix}" },
    { Effect = "Allow", Action = "secretsmanager:*", Resource = "${local.arn}:secretsmanager:${var.region}:${var.account_id}:secret:${var.prefix}/mongodb-*" },
    { Effect = "Allow", Action = "s3:*", Resource = flatten([for kind in ["audit", "backup"] : ["${local.arn}:s3:::${var.prefix}-${kind}-${var.account_id}-${var.region}", "${local.arn}:s3:::${var.prefix}-${kind}-${var.account_id}-${var.region}/*"]]) }
  ] })
}
resource "aws_iam_role_policy" "app" {
  name = "describe-app-cluster"
  role = aws_iam_role.ci["app"].id
  policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect = "Allow", Action = "eks:DescribeCluster", Resource = "${local.arn}:eks:${var.region}:${var.account_id}:cluster/${var.prefix}"
    }, {
    Effect = "Allow", Action = ["elasticloadbalancing:DescribeLoadBalancers", "elasticloadbalancing:DescribeListeners"], Resource = "*", Condition = { StringEquals = { "aws:RequestedRegion" = var.region } }
  }] })
}

# Publishing has no EKS/state access and needs no additional GitHub environment.
resource "aws_iam_role" "publisher" {
  name = "${var.prefix}-ci-publish"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect    = "Allow", Action = "sts:AssumeRoleWithWebIdentity",
    Principal = { Federated = local.oidc_arn },
    Condition = { StringEquals = {
      "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com",
      "token.actions.githubusercontent.com:sub" = "${local.github_subject_prefix}:ref:refs/heads/main"
    } }
  }] })
}
resource "aws_iam_role_policy" "ecr" {
  for_each = { publish = aws_iam_role.publisher.id, app = aws_iam_role.ci["app"].id }
  name     = "tasky-ecr-${each.key}"
  role     = each.value
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = ["ecr:GetAuthorizationToken"], Resource = "*" },
    { Effect = "Allow", Action = concat(
      ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"],
      each.key == "publish" ? ["ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload", "ecr:PutImage"] : []
    ), Resource = "${local.arn}:ecr:${var.region}:${var.account_id}:repository/${var.prefix}/tasky" }
  ] })
}

# Privileged Kubernetes setup is isolated from normal app deployment and TF state.
resource "aws_iam_role_policy" "cluster" {
  name = "cluster-setup"
  role = aws_iam_role.ci["cluster"].id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = "eks:DescribeCluster", Resource = "${local.arn}:eks:${var.region}:${var.account_id}:cluster/${var.prefix}" },
    { Effect = "Allow", Action = "secretsmanager:GetSecretValue", Resource = "${local.arn}:secretsmanager:${var.region}:${var.account_id}:secret:${var.prefix}/mongodb-*" },
    { Effect = "Allow", Action = "ssm:SendCommand", Resource = "${local.arn}:ssm:${var.region}:${var.account_id}:document/${var.prefix}-mongodb-ca" },
    { Effect = "Allow", Action = "ssm:SendCommand", Resource = "${local.arn}:ec2:${var.region}:${var.account_id}:instance/*", Condition = { StringEquals = { "ssm:resourceTag/Name" = "${var.prefix}-mongodb" } } },
    { Effect = "Allow", Action = "ssm:GetCommandInvocation", Resource = "*" }
  ] })
}
resource "aws_iam_role_policy" "apply_ssm_document" {
  name = "mongodb-ca-document"
  role = aws_iam_role.ci["apply"].id
  policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect = "Allow", Action = ["ssm:CreateDocument", "ssm:UpdateDocument", "ssm:UpdateDocumentDefaultVersion", "ssm:DeleteDocument", "ssm:DescribeDocument", "ssm:DescribeDocumentPermission", "ssm:GetDocument", "ssm:ListDocumentVersions", "ssm:ListTagsForResource", "ssm:AddTagsToResource", "ssm:RemoveTagsFromResource"], Resource = "${local.arn}:ssm:${var.region}:${var.account_id}:document/${var.prefix}-mongodb-ca"
  }] })
}
resource "aws_iam_role_policy" "plan_ssm_document" {
  name = "mongodb-ca-document-read"
  role = aws_iam_role.ci["plan"].id
  policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect = "Allow", Action = ["ssm:DescribeDocument", "ssm:DescribeDocumentPermission", "ssm:GetDocument", "ssm:ListDocumentVersions", "ssm:ListTagsForResource"], Resource = "${local.arn}:ssm:${var.region}:${var.account_id}:document/${var.prefix}-mongodb-ca"
  }] })
}
