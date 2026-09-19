resource "aws_iam_role" "mongodb" {
  permissions_boundary = var.workload_permissions_boundary_arn
  name                 = "${var.prefix}-mongodb"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole"
  }] })
}
resource "aws_iam_instance_profile" "mongodb" {
  name = "${var.prefix}-mongodb"
  role = aws_iam_role.mongodb.name
}
resource "aws_iam_policy" "mongodb" {
  name = "${var.prefix}-mongodb-privilege-creep"
  # DELIBERATE: host needs only one backup prefix, but inherited fleet permissions
  # permit EC2 lifecycle changes and access to every object in this account's S3.
  # No AdministratorAccess, IAM writes, public bucket writes or PassRole.
  policy = jsonencode({ Version = "2012-10-17", Statement = concat([
    { Sid = "ExcessiveEC2DiscoveryAndLifecycle", Effect = "Allow", Action = ["ec2:Describe*", "ec2:RunInstances", "ec2:StartInstances", "ec2:StopInstances", "ec2:CreateTags"], Resource = "*" },
    { Sid = "ExcessiveS3DataAccess", Effect = "Allow", Action = ["s3:ListBucket", "s3:GetObject", "s3:PutObject", "s3:DeleteObject"], Resource = ["${local.aws_prefix}:s3:::*"], Condition = { StringEquals = { "s3:ResourceAccount" = var.account_id } } },
    { Sid = "ReadDatabaseCredentials", Effect = "Allow", Action = "secretsmanager:GetSecretValue", Resource = local.mongodb_secret_arn }
    ], var.mongodb_secret_kms_key_arn == null ? [] : [
    { Sid = "DecryptDatabaseCredentials", Effect = "Allow", Action = "kms:Decrypt", Resource = var.mongodb_secret_kms_key_arn, Condition = { StringEquals = { "kms:ViaService" = "secretsmanager.${var.region}.amazonaws.com" } } }
  ]) })
}
resource "aws_iam_role_policy_attachment" "mongodb" {
  role       = aws_iam_role.mongodb.name
  policy_arn = aws_iam_policy.mongodb.arn
}
