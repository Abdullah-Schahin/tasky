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
    { Sid = "ExcludeExerciseWorkloads", Effect = "Deny", Principal = "*", Action = "s3:*", Resource = [local.bucket_arn, "${local.bucket_arn}/*"], Condition = { ArnEquals = { "aws:PrincipalArn" = concat(local.workload_roles, [aws_iam_role.ci["app"].arn]) } } }
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
