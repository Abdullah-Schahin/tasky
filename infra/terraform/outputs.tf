output "region" { value = var.region }
output "vpc_id" { value = aws_vpc.main.id }
output "public_subnet_ids" { value = [for s in aws_subnet.public : s.id] }
output "private_subnet_ids" { value = [for s in aws_subnet.private : s.id] }
output "cluster_name" { value = aws_eks_cluster.main.name }
output "cluster_endpoint" { value = aws_eks_cluster.main.endpoint }
output "ecr_repository_url" { value = aws_ecr_repository.tasky.repository_url }
output "mongodb_private_ip" { value = aws_instance.mongodb.private_ip }
output "mongodb_public_ip" { value = aws_instance.mongodb.public_ip }
output "mongodb_ssh" { value = "ssh ubuntu@${aws_instance.mongodb.public_ip}" }
output "mongodb_tls_uri_template" {
  value = "mongodb://tasky_app:URL_ENCODED_APP_PASSWORD@${aws_instance.mongodb.private_ip}:27017/go-mongodb?authSource=admin&tls=true&tlsCAFile=/etc/tasky-mongo-tls/ca.crt"
}
output "backup_bucket" { value = aws_s3_bucket.backup.id }
output "audit_bucket" { value = aws_s3_bucket.audit.id }
output "cloudtrail_arn" { value = var.existing_cloudtrail_arn != null ? var.existing_cloudtrail_arn : aws_cloudtrail.main[0].arn }
output "security_services" {
  value = {
    config       = var.enable_config
    security_hub = var.enable_security_hub
    guardduty    = var.enable_guardduty
  }
}
output "load_balancer_controller_role_arn" { value = aws_iam_role.load_balancer_controller.arn }
output "kubectl_setup" { value = "aws eks update-kubeconfig --profile wiz --region ${var.region} --name ${aws_eks_cluster.main.name}" }
output "helm_aws_values" {
  description = "Non-secret values; supply your own verified image, hostname, and ACM certificate."
  value = yamlencode({
    ingress = {
      className      = "alb"
      host           = "REPLACE_WITH_HOSTNAME"
      certificateArn = "REPLACE_WITH_ACM_CERTIFICATE_ARN"
      publicSubnets  = [for s in aws_subnet.public : s.id]
    }
    mongodbTLS = { existingSecret = "tasky-mongo-ca" }
  })
}
output "mongodb_secret_arn" {
  description = "ARN only, never credential values."
  value       = local.mongodb_secret_arn
}
