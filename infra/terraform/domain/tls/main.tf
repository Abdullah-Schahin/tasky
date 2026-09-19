variable "hosted_zone_id" {
  type = string
  validation {
    condition     = can(regex("^Z[A-Z0-9]+$", var.hosted_zone_id))
    error_message = "Use the zone ID output from domain-registration."
  }
}
# Registration creates a public zone. Adopt it; never create a duplicate zone.
import {
  to = aws_route53_zone.main
  id = var.hosted_zone_id
}
resource "aws_route53_zone" "main" {
  name          = "abu-pse.link"
  force_destroy = false
  lifecycle { prevent_destroy = true }
}
resource "aws_acm_certificate" "app" {
  domain_name       = "tasky.abu-pse.link"
  validation_method = "DNS"
  lifecycle { create_before_destroy = true }
}
resource "aws_route53_record" "validation" {
  zone_id = aws_route53_zone.main.zone_id
  name    = one(aws_acm_certificate.app.domain_validation_options).resource_record_name
  type    = one(aws_acm_certificate.app.domain_validation_options).resource_record_type
  ttl     = 300
  records = [one(aws_acm_certificate.app.domain_validation_options).resource_record_value]
}
resource "aws_acm_certificate_validation" "app" {
  certificate_arn         = aws_acm_certificate.app.arn
  validation_record_fqdns = [aws_route53_record.validation.fqdn]
  timeouts { create = "60m" }
}
output "app_domain" { value = aws_acm_certificate.app.domain_name }
output "certificate_arn" { value = aws_acm_certificate_validation.app.certificate_arn }
output "hosted_zone_id" { value = aws_route53_zone.main.zone_id }
