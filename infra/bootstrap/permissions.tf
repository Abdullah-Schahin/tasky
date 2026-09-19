# Discovery metadata only: no general S3 object reads or database secret values.
resource "aws_iam_policy" "discovery" {
  name = "${var.prefix}-ci-discovery"
  policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect = "Allow", Resource = "*", Action = [
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
    { Effect = "Allow", Action = ["iam:CreateInstanceProfile", "iam:DeleteInstanceProfile", "iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile", "iam:TagInstanceProfile", "iam:UntagInstanceProfile"], Resource = "${local.account_arn}:instance-profile/${var.prefix}-mongodb" },
    { Effect = "Allow", Action = "iam:PassRole", Resource = local.workload_roles, Condition = { StringEquals = { "iam:PassedToService" = ["ec2.amazonaws.com", "eks.amazonaws.com", "config.amazonaws.com"] } } },
    { Effect = "Allow", Action = ["iam:CreateOpenIDConnectProvider", "iam:DeleteOpenIDConnectProvider", "iam:UpdateOpenIDConnectProviderThumbprint", "iam:AddClientIDToOpenIDConnectProvider", "iam:RemoveClientIDFromOpenIDConnectProvider", "iam:TagOpenIDConnectProvider", "iam:UntagOpenIDConnectProvider"], Resource = "${local.account_arn}:oidc-provider/oidc.eks.${var.region}.amazonaws.com/id/*" },
    { Effect = "Allow", Action = "iam:CreateServiceLinkedRole", Resource = "${local.account_arn}:role/aws-service-role/*", Condition = { StringEquals = { "iam:AWSServiceName" = ["eks.amazonaws.com", "eks-nodegroup.amazonaws.com", "autoscaling.amazonaws.com", "elasticloadbalancing.amazonaws.com"] } } }
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
  }] })
}
