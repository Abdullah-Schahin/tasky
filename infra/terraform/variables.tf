variable "region" {
  description = "CloudLabs-approved AWS region."
  type        = string
}
variable "account_id" {
  description = "Expected sandbox account; prevents accidental deployment to another account."
  type        = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "Supply the 12-digit sandbox account ID."
  }
}
variable "prefix" {
  type    = string
  default = "tasky-wiz"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,19}$", var.prefix))
    error_message = "Use 3-20 lowercase letters/digits/hyphens, starting with a letter."
  }
}
variable "availability_zones" {
  description = "Exactly two available standard AZs in the selected region."
  type        = list(string)
  validation {
    condition     = length(var.availability_zones) == 2 && length(toset(var.availability_zones)) == 2
    error_message = "Two distinct AZs are required; check sandbox capacity before planning."
  }
}
variable "vpc_cidr" {
  type    = string
  default = "10.42.0.0/16"
  validation {
    condition     = can(cidrsubnet(var.vpc_cidr, 8, 11))
    error_message = "Supply an IPv4 VPC CIDR with room for the subnet layout."
  }
}
variable "eks_version" {
  description = "EKS version available in the sandbox; keep within standard support."
  type        = string
  default     = "1.35"
}
variable "eks_admin_principal_arn" {
  description = "Existing IAM user or role ARN (not an STS session) for kubectl administrators."
  type        = string
  validation {
    condition     = can(regex("^arn:aws[^:]*:iam::[0-9]{12}:(role|user)/.+$", var.eks_admin_principal_arn))
    error_message = "Use an existing IAM user or role ARN, not an assumed-role session ARN."
  }
}
variable "eks_public_access_cidrs" {
  description = "Optional operator IPv4 /32s for the authenticated EKS API. Empty means private API only. Nodes remain private."
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for c in var.eks_public_access_cidrs : can(cidrnetmask(c)) && endswith(c, "/32")])
    error_message = "Only explicit operator IPv4 /32s are accepted."
  }
}
variable "node_instance_type" {
  type    = string
  default = "t3.medium"
}
variable "mongodb_ami_id" {
  description = "Pinned Canonical Ubuntu 20.04 or 22.04 amd64 AMI at least one year old; validate availability in this region."
  type        = string
  validation {
    condition     = can(regex("^ami-[a-f0-9]+$", var.mongodb_ami_id))
    error_message = "A verified regional AMI ID is required."
  }
}
variable "mongodb_ubuntu_codename" {
  type    = string
  default = "focal"
  validation {
    condition     = contains(["focal", "jammy"], var.mongodb_ubuntu_codename)
    error_message = "Use focal (20.04) or jammy (22.04), matching the pinned AMI."
  }
}
variable "mongodb_instance_type" {
  type    = string
  default = "t3.medium"
}
variable "ssh_public_key" {
  description = "Public SSH key only; never supply a private key."
  type        = string
  validation {
    condition     = can(regex("^(ssh-ed25519|ssh-rsa) [A-Za-z0-9+/=]+", var.ssh_public_key))
    error_message = "Supply an SSH public key."
  }
}
variable "mongodb_secret_arn" {
  description = "Optional existing secret ARN. Otherwise create credentials using ephemeral random passwords and a write-only secret version."
  type        = string
  default     = null
  validation {
    condition     = var.mongodb_secret_arn == null || can(regex("^arn:aws[^:]*:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:.+$", var.mongodb_secret_arn))
    error_message = "Supply the existing database credential secret ARN."
  }
}
variable "mongodb_secret_kms_key_arn" {
  description = "Set only if the existing secret uses a customer-managed KMS key."
  type        = string
  default     = null
}
variable "existing_cloudtrail_arn" {
  description = "Reuse an independently verified logging management-event trail; null creates one for this stack."
  type        = string
  default     = null
}
variable "enable_config" {
  description = "Create Config recorder, delivery channel and rules. Inspect/import existing account configuration first."
  type        = bool
  default     = true
}
variable "enable_security_hub" {
  description = "Optional account-level service. Enable only after confirming sandbox support and absence of an existing hub."
  type        = bool
  default     = false
}
variable "enable_guardduty" {
  description = "Optional regional service. Enable only after confirming sandbox support and absence of an existing detector."
  type        = bool
  default     = false
}
