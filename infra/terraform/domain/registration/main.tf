variable "contact" {
  sensitive = true
  type = object({
    first_name        = string
    last_name         = string
    contact_type      = optional(string, "PERSON")
    organization_name = optional(string)
    email             = string
    phone_number      = string
    address_line_1    = string
    address_line_2    = optional(string)
    city              = string
    state             = optional(string)
    country_code      = string
    zip_code          = string
  })
  validation {
    condition     = can(regex("^\\+[0-9]+\\.[0-9]+$", var.contact.phone_number)) && can(regex("^[A-Z]{2}$", var.contact.country_code))
    error_message = "Use a +countrycode.number phone and two-letter uppercase country code."
  }
}
resource "aws_route53domains_domain" "main" {
  domain_name        = "abu-pse.link"
  duration_in_years  = 1
  auto_renew         = false
  transfer_lock      = true
  admin_privacy      = true
  registrant_privacy = true
  tech_privacy       = true
  lifecycle { prevent_destroy = true }
  timeouts { create = "60m" }
  admin_contact {
    first_name        = var.contact.first_name
    last_name         = var.contact.last_name
    contact_type      = var.contact.contact_type
    organization_name = var.contact.organization_name
    email             = var.contact.email
    phone_number      = var.contact.phone_number
    address_line_1    = var.contact.address_line_1
    address_line_2    = var.contact.address_line_2
    city              = var.contact.city
    state             = var.contact.state
    country_code      = var.contact.country_code
    zip_code          = var.contact.zip_code
  }
  registrant_contact {
    first_name        = var.contact.first_name
    last_name         = var.contact.last_name
    contact_type      = var.contact.contact_type
    organization_name = var.contact.organization_name
    email             = var.contact.email
    phone_number      = var.contact.phone_number
    address_line_1    = var.contact.address_line_1
    address_line_2    = var.contact.address_line_2
    city              = var.contact.city
    state             = var.contact.state
    country_code      = var.contact.country_code
    zip_code          = var.contact.zip_code
  }
  tech_contact {
    first_name        = var.contact.first_name
    last_name         = var.contact.last_name
    contact_type      = var.contact.contact_type
    organization_name = var.contact.organization_name
    email             = var.contact.email
    phone_number      = var.contact.phone_number
    address_line_1    = var.contact.address_line_1
    address_line_2    = var.contact.address_line_2
    city              = var.contact.city
    state             = var.contact.state
    country_code      = var.contact.country_code
    zip_code          = var.contact.zip_code
  }
}
output "hosted_zone_id" { value = aws_route53domains_domain.main.hosted_zone_id }
output "domain_name" { value = aws_route53domains_domain.main.domain_name }
