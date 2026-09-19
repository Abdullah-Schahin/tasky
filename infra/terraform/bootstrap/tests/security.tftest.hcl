mock_provider "aws" {
  mock_resource "aws_iam_policy" {
    defaults = { arn = "arn:aws:iam::516027198761:policy/mock" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::516027198761:role/mock" }
  }
  mock_resource "aws_iam_openid_connect_provider" {
    defaults = { arn = "arn:aws:iam::516027198761:oidc-provider/token.actions.githubusercontent.com" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
}
variables {
  region            = "us-east-1"
  account_id        = "516027198761"
  github_repository = "Abdullah-Schahin/tasky"
}
run "identity_and_state_isolation" {
  command = apply
  assert {
    condition = alltrue([for key, role in aws_iam_role.ci :
      jsondecode(role.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == "repo:Abdullah-Schahin/tasky:environment:${local.environments[key]}" &&
      jsondecode(role.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:aud"] == "sts.amazonaws.com"
    ])
    error_message = "Every CI role must trust only its exact repository/environment and STS audience."
  }
  assert {
    condition     = aws_s3_bucket_public_access_block.state.block_public_acls && aws_s3_bucket_public_access_block.state.ignore_public_acls && aws_s3_bucket_public_access_block.state.block_public_policy && aws_s3_bucket_public_access_block.state.restrict_public_buckets && aws_s3_bucket_versioning.state.versioning_configuration[0].status == "Enabled"
    error_message = "State must be private and versioned."
  }
  assert {
    condition     = alltrue([for s in jsondecode(aws_iam_role_policy.state["plan"].policy).Statement : !contains(s.Action, "s3:PutObject") || s.Resource != "${local.bucket_arn}/${var.state_key}"])
    error_message = "Plan must not write infrastructure state."
  }
  assert {
    condition     = jsondecode(aws_iam_role_policy.app.policy).Statement[0].Action == "eks:DescribeCluster" && length(jsondecode(aws_iam_role_policy.app.policy).Statement) == 1
    error_message = "The app role must not gain infrastructure or state privileges."
  }
  assert {
    condition     = contains(jsondecode(aws_s3_bucket_policy.state.policy).Statement[1].Condition.ArnEquals["aws:PrincipalArn"], "arn:aws:iam::516027198761:role/tasky-wiz-mongodb") && jsondecode(aws_s3_bucket_policy.state.policy).Statement[1].Effect == "Deny"
    error_message = "The deliberately overprivileged Mongo role must be denied state access."
  }
  assert {
    condition     = jsondecode(aws_iam_role_policy.apply_iam.policy).Statement[0].Condition.StringEquals["iam:PermissionsBoundary"] == aws_iam_policy.workload_boundary.arn && alltrue([for s in jsondecode(aws_iam_role_policy.apply_iam.policy).Statement : !contains(try(tolist(s.Action), [s.Action]), "iam:DeleteRolePermissionsBoundary")])
    error_message = "Apply must enforce the boundary and must not remove it."
  }
}
run "policy_size_limits" {
  command = apply
  assert {
    condition     = length(aws_iam_role_policy.apply_iam.policy) + length(aws_iam_role_policy.apply_services.policy) + length(aws_iam_role_policy.state["apply"].policy) <= 10240 && length(aws_iam_policy.discovery.policy) <= 6144 && length(aws_iam_policy.workload_boundary.policy) <= 6144
    error_message = "Policies must fit the AWS role inline and managed policy size quotas."
  }
}
run "reuse_existing_oidc" {
  command = plan
  variables {
    github_oidc_provider_arn = "arn:aws:iam::516027198761:oidc-provider/token.actions.githubusercontent.com"
  }
  assert {
    condition     = length(aws_iam_openid_connect_provider.github) == 0
    error_message = "Reusing an existing GitHub provider must not create a duplicate."
  }
}

run "scoped_app_dns" {
  command = apply
  variables { app_dns_zone_id = "ZTEST123" }
  assert {
    condition     = jsondecode(aws_iam_role_policy.app_dns[0].policy).Statement[1].Resource == "arn:aws:route53:::hostedzone/ZTEST123" && jsondecode(aws_iam_role_policy.app_dns[0].policy).Statement[1].Condition["ForAllValues:StringEquals"]["route53:ChangeResourceRecordSetsNormalizedRecordNames"][0] == "tasky.abu-pse.link"
    error_message = "App role DNS writes must target only its own name in the selected zone."
  }
  assert {
    condition     = jsondecode(aws_s3_bucket_policy.state.policy).Statement[2].Effect == "Deny" && contains(jsondecode(aws_s3_bucket_policy.state.policy).Statement[2].Resource, "${local.bucket_arn}/domain-registration/*")
    error_message = "App deployment must not read registration contact state."
  }
}
