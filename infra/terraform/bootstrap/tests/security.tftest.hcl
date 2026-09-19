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
  region                     = "us-east-1"
  account_id                 = "516027198761"
  github_repository          = "Abdullah-Schahin/tasky"
  github_repository_owner_id = "33698941"
  github_repository_id       = "1374160582"
}
run "identity_and_state_isolation" {
  command = apply
  assert {
    condition = alltrue([for key, role in aws_iam_role.ci :
      jsondecode(role.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == "repo:Abdullah-Schahin@33698941/tasky@1374160582:environment:${local.environments[key]}" &&
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
    condition     = jsondecode(aws_iam_role_policy.app.policy).Statement[0].Action == "eks:DescribeCluster" && length(jsondecode(aws_iam_role_policy.app.policy).Statement) == 2 && alltrue([for s in jsondecode(aws_iam_role_policy.app.policy).Statement : alltrue([for a in try(tolist(s.Action), [s.Action]) : startswith(a, "eks:Describe") || startswith(a, "elasticloadbalancing:Describe")])])
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
run "bucket_discovery_scope" {
  command = plan
  assert {
    condition = jsondecode(aws_iam_policy.discovery.policy).Statement[1].Action == ["s3:ListBucket"] && toset(jsondecode(aws_iam_policy.discovery.policy).Statement[1].Resource) == toset([
      "arn:aws:s3:::tasky-wiz-audit-516027198761-us-east-1",
      "arn:aws:s3:::tasky-wiz-backup-516027198761-us-east-1"
    ])
    error_message = "Bucket existence checks must be allowed only for the two platform buckets, without object access."
  }
}
run "reuse_existing_oidc" {
  command = plan
  variables {
    AWS_GITHUB_OIDC_PROVIDER_ARN = "arn:aws:iam::516027198761:oidc-provider/token.actions.githubusercontent.com"
  }
  assert {
    condition     = length(aws_iam_openid_connect_provider.github) == 0
    error_message = "Reusing an existing GitHub provider must not create a duplicate."
  }
}

run "ecr_publish_and_pull_isolation" {
  command = apply
  assert {
    condition     = jsondecode(aws_iam_role.publisher.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == "repo:Abdullah-Schahin@33698941/tasky@1374160582:ref:refs/heads/main"
    error_message = "ECR publishing must trust only main in this immutable repository identity."
  }
  assert {
    condition     = alltrue([for p in aws_iam_role_policy.ecr : jsondecode(p.policy).Statement[1].Resource == "arn:aws:ecr:us-east-1:516027198761:repository/tasky-wiz/tasky"]) && !contains(jsondecode(aws_iam_role_policy.ecr["app"].policy).Statement[1].Action, "ecr:PutImage") && contains(jsondecode(aws_iam_role_policy.ecr["publish"].policy).Statement[1].Action, "ecr:PutImage")
    error_message = "Publishing must be scoped to Tasky's repository; deployment must have pull-only access."
  }
}
