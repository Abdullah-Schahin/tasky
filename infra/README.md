# Infrastructure

```text
infra/
├── terraform/
│   ├── bootstrap/             # OIDC, CI roles, protected state bucket
│   ├── platform/              # VPC, EKS, MongoDB, audit and exercise resources
│   ├── domain/
│   │   ├── registration/      # Domain ownership and private contact details
│   │   └── tls/               # Adopt registration's zone; ACM and validation
│   └── app-dns/               # App A alias, applied after Helm creates the ALB
├── helm/                      # Tasky chart and AWS values
└── local/                     # Minikube deployment and local values
```

These are **independent Terraform roots**, separated by lifecycle, deployment identity
and state access. Domain ownership survives platform teardown; app deployment cannot
read registrar contacts. Registration must complete before TLS can import the AWS-created
zone, and app DNS needs the controller-created ALB. No wrapper modules, extra environments,
Terragrunt or provider-file symlinks are needed for this single-account exercise.

Small roots use `main.tf` and `versions.tf`; the larger roots separate `variables.tf`
and `outputs.tf`. Platform resources that need file-scoped Trivy exceptions remain in
`network.tf`, `mongodb.tf` and `s3-backup.tf`; the other resources are grouped in `main.tf`.
Each root declares and locks its own providers, as required for independent initialization.
Shared CI validation/input/backend logic lives in `.github/scripts/terraform_ci.py`.

## Workflows

| Workflow | Responsibility |
| --- | --- |
| **Bootstrap Infra** | Manual account bootstrap and CI IAM updates |
| **Infra CI/CD** | Validate/scan Terraform; plan/apply platform; optionally register domain and configure TLS |
| **App CI/CD** | Build/test/scan/sign image; optionally deploy Helm and its ALB DNS alias |

There is **no separate domain workflow**. In Infra CI/CD, select `include-domain` to run
the domain stages on main. Leave `apply` unchecked for planning; check it to apply the
platform (when enabled) and the selected domain stages. Domain registration remains
billable and runs in the protected `bootstrap` environment using `DOMAIN_CONTACT_JSON`
and bootstrap credentials. It depends on validation and the security gate. Normal
platform plan/apply still use their separate OIDC roles/environments.

Native Terraform tests remain. The Python test files for infrastructure setup were removed;
`tests/todo-roundtrip.js` remains the application's database integration test.

- [Bootstrap configuration](terraform/bootstrap/README.md)
- [Platform architecture and operation](terraform/platform/README.md)
- [Domain contacts, certificate and app deployment](terraform/domain/registration/README.md)
- [Helm chart](helm/README.md)
- [Local Minikube](local/README.md)

## Existing checkouts and state

| Old working directory | New working directory | S3 state key (unchanged) |
| --- | --- | --- |
| `infra/bootstrap` | `infra/terraform/bootstrap` | `bootstrap/terraform.tfstate` |
| `infra/terraform` | `infra/terraform/platform` | Existing `TF_STATE_KEY`, normally `infra/terraform.tfstate` |
| `infra/domain-registration` | `infra/terraform/domain/registration` | `domain-registration/terraform.tfstate` |
| `infra/domain-tls` | `infra/terraform/domain/tls` | `domain-tls/terraform.tfstate` |
| `infra/app-dns` | `infra/terraform/app-dns` | `app-dns/terraform.tfstate` |

Resource addresses are unchanged. **No state move/import or resource recreation is
required by this directory refactor.** Reinitialize each new working directory using
its existing backend configuration and state key, then generate a fresh plan. Never
apply an old saved plan as part of this reorganization. Local ignored inputs/state were
moved with their root in the current workspace; other checkouts must move their own
ignored files to the corresponding root. Keep existing state backups.

The layout follows HashiCorp's [configuration structure](https://developer.hashicorp.com/terraform/language/files)
and [style guidance](https://developer.hashicorp.com/terraform/language/style), retaining
separate states where permissions and resource lifecycles differ.
