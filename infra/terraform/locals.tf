data "aws_partition" "current" {}
locals {
  tags = {
    "created by" = "Abu"
    "for"        = "Wiz PSE"
    Project      = var.prefix
  }
  azs                = { for i, az in var.availability_zones : tostring(i) => az }
  mongodb_secret_arn = var.mongodb_secret_arn != null ? var.mongodb_secret_arn : aws_secretsmanager_secret.mongodb[0].arn
  aws_prefix         = "arn:${data.aws_partition.current.partition}"
}
