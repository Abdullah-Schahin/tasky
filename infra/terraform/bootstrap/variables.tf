variable "region" { type = string }
variable "account_id" {
  type = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "Supply the expected 12-digit AWS account ID."
  }
}
variable "prefix" {
  type    = string
  default = "tasky-wiz"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,19}$", var.prefix))
    error_message = "Use the same 3-20 character prefix as the infrastructure stack."
  }
}
variable "github_repository" {
  type        = string
  description = "Exact case-sensitive GitHub owner/repository."
  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "Supply owner/repository without wildcards."
  }
}
variable "AWS_GITHUB_OIDC_PROVIDER_ARN" {
  type        = string
  default     = null
  description = "Reuse the account's existing GitHub OIDC provider if present."
  validation {
    condition     = var.AWS_GITHUB_OIDC_PROVIDER_ARN == null || var.AWS_GITHUB_OIDC_PROVIDER_ARN == "arn:aws:iam::${var.account_id}:oidc-provider/token.actions.githubusercontent.com"
    error_message = "Use this account's GitHub OIDC provider ARN."
  }
}
variable "state_key" {
  type    = string
  default = "infra/terraform.tfstate"
  validation {
    condition     = can(regex("^infra/[A-Za-z0-9/_-]+\\.tfstate$", var.state_key))
    error_message = "Use a state path under infra/, ending in .tfstate."
  }
}

variable "github_repository_owner_id" {
  type        = string
  description = "Immutable GitHub owner ID, supplied automatically by Actions."
  validation {
    condition     = can(regex("^[0-9]+$", var.github_repository_owner_id))
    error_message = "Supply the numeric GitHub repository owner ID."
  }
}
variable "github_repository_id" {
  type        = string
  description = "Immutable GitHub repository ID, supplied automatically by Actions."
  validation {
    condition     = can(regex("^[0-9]+$", var.github_repository_id))
    error_message = "Supply the numeric GitHub repository ID."
  }
}
