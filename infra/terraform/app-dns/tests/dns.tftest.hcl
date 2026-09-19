mock_provider "aws" {
  mock_data "aws_lb" {
    defaults = { dns_name = "tasky.us-east-1.elb.amazonaws.com", zone_id = "ZALB123", load_balancer_type = "application", internal = false }
  }
  mock_data "aws_route53_zone" {
    defaults = { name = "abu-pse.link", private_zone = false }
  }
}
variables {
  account_id     = "516027198761"
  region         = "us-east-1"
  hosted_zone_id = "ZTEST123"
  alb_arn        = "arn:aws:elasticloadbalancing:us-east-1:516027198761:loadbalancer/app/tasky/1234567890123456"
}
run "app_alias" {
  command = plan
  assert {
    condition     = aws_route53_record.app.name == "tasky.abu-pse.link" && aws_route53_record.app.type == "A" && aws_route53_record.app.alias[0].name == "tasky.us-east-1.elb.amazonaws.com" && aws_route53_record.app.alias[0].zone_id == "ZALB123"
    error_message = "App alias must point to the discovered ALB and its canonical zone."
  }
}
