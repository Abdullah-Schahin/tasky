# Infrastructure

```text
infra/
├── terraform/
│   ├── bootstrap/   # GitHub OIDC, CI IAM roles, protected state bucket
│   └── platform/    # VPC, EKS, MongoDB, audit resources
├── helm/            # Tasky chart and AWS values
└── local/           # Minikube deployment
```

Terraform roots are separated by deployment identity and lifecycle. Existing resource
addresses and bootstrap/platform state keys remain unchanged. Platform state stays at
`infra/terraform.tfstate`; bootstrap state stays at `bootstrap/terraform.tfstate`.

The exercise deliberately uses HTTP on the AWS-generated ALB hostname. No domain
registration, Route 53 records, FreeDNS configuration or ACM certificate is needed.
Missing public TLS is an expected security finding; MongoDB TLS remains enabled.

- **Bootstrap Infra**: manually create/update IAM and protected state storage.
- **Infra CI/CD**: scan/validate, plan, and optionally apply the platform.
- **App CI/CD**: build/test/scan/sign, deploy Helm after approval, and output the HTTP URL.

See [HTTP demo and expected weakness](http-demo.md), [bootstrap setup](terraform/bootstrap/README.md),
[platform operation](terraform/platform/README.md), [Helm](helm/README.md), and
[local Minikube](local/README.md).

## Existing state

The failed registrar request created no domain according to the reported error. This
code change does not run Terraform destroy or delete any local/remote state. Retain
any old registration/TLS/app-DNS state backups. If either of the old TLS or app-DNS
roots was applied independently, inventory those resources before retiring their
state; removing source files does not destroy or migrate existing AWS resources.
Regenerate saved plans after these changes.
