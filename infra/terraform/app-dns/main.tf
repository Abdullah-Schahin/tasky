variable "hosted_zone_id" { type = string }
variable "alb_arn" { type = string }
data "aws_lb" "app" { arn = var.alb_arn }
data "aws_route53_zone" "main" {
  zone_id      = var.hosted_zone_id
  private_zone = false
}
resource "aws_route53_record" "app" {
  zone_id = var.hosted_zone_id
  name    = "tasky.abu-pse.link"
  type    = "A"
  alias {
    name                   = data.aws_lb.app.dns_name
    zone_id                = data.aws_lb.app.zone_id
    evaluate_target_health = true
  }
  lifecycle {
    precondition {
      condition     = trimsuffix(data.aws_route53_zone.main.name, ".") == "abu-pse.link" && !data.aws_route53_zone.main.private_zone
      error_message = "App DNS must use the public abu-pse.link zone."
    }
    precondition {
      condition     = data.aws_lb.app.load_balancer_type == "application" && !data.aws_lb.app.internal
      error_message = "App DNS must target an internet-facing ALB."
    }
  }
}
output "url" { value = "https://${aws_route53_record.app.fqdn}" }
