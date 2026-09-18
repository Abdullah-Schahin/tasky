# CI requires an existing private, versioned, encrypted S3 state bucket.
# Credentials come from OIDC/environment, never backend files or Terraform values.
terraform {
  backend "s3" {}
}
