# Infrastructure

```text
infra/
├── terraform/
│   ├── bootstrap/   # GitHub OIDC, CI IAM roles, protected state bucket
│   └── platform/    # VPC, EKS, MongoDB, audit resources, ACM certificate
├── helm/            # Tasky chart and AWS values
└── local/           # Minikube deployment
```

Terraform roots are separated by deployment identity and lifecycle. Existing resource
addresses and bootstrap/platform state keys remain unchanged. Platform state stays at
`infra/terraform.tfstate`; bootstrap state stays at `bootstrap/terraform.tfstate`.

Domain registration and Route 53 TLS/app-DNS roots have been removed. The exercise
uses the externally managed FreeDNS hostname `tasky-abu-pse.apps.dj`. No registrar,
Route 53 hosted zone, or Route 53 record is provisioned. ACM is part of the platform.

- **Bootstrap Infra**: manually create/update IAM and protected state storage.
- **Infra CI/CD**: scan/validate, plan, and optionally apply the platform. The apply
  summary contains the ACM ARN and the CNAME to add in FreeDNS.
- **App CI/CD**: build/test/scan/sign, optionally deploy Helm, and output the ALB
  hostname for the FreeDNS application CNAME.

See [FreeDNS and HTTPS setup](freedns.md), [bootstrap setup](terraform/bootstrap/README.md),
[platform operation](terraform/platform/README.md), [Helm](helm/README.md), and
[local Minikube](local/README.md).

## Existing state

The failed registrar request created no domain according to the reported error. This
code change does not run Terraform destroy or delete any local/remote state. Retain
any old registration/TLS/app-DNS state backups. If either of the old TLS or app-DNS
roots was applied independently, inventory those resources before retiring their
state; removing source files does not destroy or migrate existing AWS resources.
Regenerate saved plans after these changes.
