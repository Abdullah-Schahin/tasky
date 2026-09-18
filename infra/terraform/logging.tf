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
