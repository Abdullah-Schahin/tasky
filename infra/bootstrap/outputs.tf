output "github_variables" {
  value = {
    AWS_REGION              = var.region
    AWS_ACCOUNT_ID          = var.account_id
    AWS_TF_PLAN_ROLE_ARN    = aws_iam_role.ci["plan"].arn
    AWS_TF_APPLY_ROLE_ARN   = aws_iam_role.ci["apply"].arn
    AWS_APP_DEPLOY_ROLE_ARN = aws_iam_role.ci["app"].arn
    TF_STATE_BUCKET         = aws_s3_bucket.state.id
    TF_STATE_KEY            = var.state_key
  }
}
output "infrastructure_inputs" {
  value = {
    workload_permissions_boundary_arn = aws_iam_policy.workload_boundary.arn
    app_deploy_role_arn               = aws_iam_role.ci["app"].arn
  }
}
output "backend_config" {
  value = <<-EOT
    bucket = "${aws_s3_bucket.state.id}"
    key = "${var.state_key}"
    region = "${var.region}"
    encrypt = true
    use_lockfile = true
    allowed_account_ids = ["${var.account_id}"]
  EOT
}
