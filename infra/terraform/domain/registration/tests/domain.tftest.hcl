mock_provider "aws" {}
variables {
  account_id = "516027198761"
  region     = "us-east-1"
  contact = {
    first_name     = "Example"
    last_name      = "Test"
    email          = "test@example.invalid"
    phone_number   = "+49.123456789"
    address_line_1 = "1 Example Street"
    city           = "Berlin"
    country_code   = "DE"
    zip_code       = "10115"
  }
}
run "registration_defaults" {
  command = plan
  assert {
    condition     = aws_route53domains_domain.main.domain_name == "abu-pse.link" && aws_route53domains_domain.main.duration_in_years == 1 && !aws_route53domains_domain.main.auto_renew && aws_route53domains_domain.main.transfer_lock
    error_message = "Only the requested one-year domain registration is allowed, without automatic renewal."
  }
  assert {
    condition     = aws_route53domains_domain.main.admin_privacy && aws_route53domains_domain.main.registrant_privacy && aws_route53domains_domain.main.tech_privacy
    error_message = "All contacts must have privacy enabled."
  }
}
