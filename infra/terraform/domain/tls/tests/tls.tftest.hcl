mock_provider "aws" {
  mock_resource "aws_acm_certificate" {
    defaults = {
      arn                       = "arn:aws:acm:us-east-1:516027198761:certificate/11111111-1111-1111-1111-111111111111"
      domain_validation_options = [{ domain_name = "tasky.abu-pse.link", resource_record_name = "_test.tasky.abu-pse.link", resource_record_type = "CNAME", resource_record_value = "_test.acm-validations.aws." }]
    }
  }
}
variables {
  account_id     = "516027198761"
  region         = "us-east-1"
  hosted_zone_id = "ZTEST123"
}
run "tls_hostname" {
  command = plan
  assert {
    condition     = aws_acm_certificate.app.domain_name == "tasky.abu-pse.link" && aws_acm_certificate.app.validation_method == "DNS" && aws_route53_zone.main.name == "abu-pse.link"
    error_message = "Certificate and zone must match the requested domain."
  }
}

override_resource {
  target = aws_route53_zone.main
  values = { zone_id = "ZTEST123", name = "abu-pse.link" }
}
