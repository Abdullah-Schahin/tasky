# Passwords flow directly from ephemeral generation to the provider's write-only
# argument. Terraform records metadata/version, not the password material.
ephemeral "random_password" "mongodb" {
  for_each = var.mongodb_secret_arn == null ? toset(["admin_password", "app_password", "backup_password"]) : toset([])
  length   = 32
  special  = false
}
resource "aws_secretsmanager_secret" "mongodb" {
  count                   = var.mongodb_secret_arn == null ? 1 : 0
  name                    = "${var.prefix}/mongodb"
  description             = "MongoDB exercise credentials; fetched at EC2 bootstrap"
  kms_key_id              = var.mongodb_secret_kms_key_arn
  recovery_window_in_days = 7
}
resource "aws_secretsmanager_secret_version" "mongodb" {
  count                    = var.mongodb_secret_arn == null ? 1 : 0
  secret_id                = aws_secretsmanager_secret.mongodb[0].id
  secret_string_wo         = jsonencode({ for k, v in ephemeral.random_password.mongodb : k => v.result })
  secret_string_wo_version = 1
}
