resource "aws_s3_bucket" "backup" {
  bucket        = "${var.prefix}-backup-${var.account_id}-${var.region}"
  force_destroy = false
}
resource "aws_s3_bucket_ownership_controls" "backup" {
  bucket = aws_s3_bucket.backup.id
  rule { object_ownership = "BucketOwnerEnforced" }
}
resource "aws_s3_bucket_public_access_block" "backup" {
  bucket             = aws_s3_bucket.backup.id
  block_public_acls  = true
  ignore_public_acls = true
  # DELIBERATE: public policy allows anonymous listing/reading, but never writing.
  block_public_policy     = false
  restrict_public_buckets = false
}
resource "aws_s3_bucket_server_side_encryption_configuration" "backup" {
  bucket = aws_s3_bucket.backup.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}
resource "aws_s3_bucket_policy" "backup" {
  bucket = aws_s3_bucket.backup.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Sid = "ExercisePublicList", Effect = "Allow", Principal = "*", Action = "s3:ListBucket", Resource = aws_s3_bucket.backup.arn },
    { Sid = "ExercisePublicRead", Effect = "Allow", Principal = "*", Action = "s3:GetObject", Resource = "${aws_s3_bucket.backup.arn}/*" },
    { Sid = "DenyInsecureTransport", Effect = "Deny", Principal = "*", Action = "s3:*", Resource = [aws_s3_bucket.backup.arn, "${aws_s3_bucket.backup.arn}/*"], Condition = { Bool = { "aws:SecureTransport" = "false" } } }
  ] })
  depends_on = [aws_s3_bucket_public_access_block.backup]
}
# DELIBERATE: no versioning and no encryption-enforcement bucket policy.
# Default SSE-S3 remains enabled; public access is not the same as unencrypted storage.
