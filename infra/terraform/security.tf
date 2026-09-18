resource "aws_iam_role" "config" {
  count = var.enable_config ? 1 : 0
  name  = "${var.prefix}-config"
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
# Optional services are opt-in, avoiding unsupported-service apply failures by default.
# Terraform cannot catch AWS AccessDenied and continue an apply; inspect before enabling.
resource "aws_securityhub_account" "main" {
  count                    = var.enable_security_hub ? 1 : 0
  enable_default_standards = true
}
resource "aws_guardduty_detector" "main" {
  count  = var.enable_guardduty ? 1 : 0
  enable = true
}
