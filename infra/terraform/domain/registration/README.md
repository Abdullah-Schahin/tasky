# abu-pse.link registration and Tasky HTTPS

This is prepared code, not an executed registration. AWS reported `abu-pse.link`
AVAILABLE during the read-only check on 2026-09-19; availability can change. The
**Infra CI/CD** workflow registers it only when manually run
on main with `apply=true`. Registration is billable for one year. Auto-renew is
explicitly disabled for this lab; monitor expiry or deliberately enable renewal.

The resource split avoids duplicate hosted zones and keeps domain ownership outside
of disposable EKS infrastructure:

| Stack | Resources/state |
| --- | --- |
| `infra/terraform/domain/registration` | Registers `abu-pse.link`; AWS creates its public hosted zone. State: `domain-registration/terraform.tfstate` |
| `infra/terraform/domain/tls` | Imports that same zone, tags it, requests ACM for `tasky.abu-pse.link`, creates its validation CNAME, and waits for issuance. State: `domain-tls/terraform.tfstate` |
| `infra/terraform/app-dns` | One A alias to the ALB created by the Kubernetes ingress controller. State: `app-dns/terraform.tfstate` |

All taggable managed resources use `created by=Abu` and `for=Wiz PSE`. Route 53
records and the ACM validation waiter do not support tags. Domain and zone have
`prevent_destroy`; ACM uses create-before-destroy. The registrar's zone is adopted
using a Terraform import block after registration, never a second zone.

## 1. Registration workflow

First complete bootstrap. In the protected `bootstrap` GitHub environment set:

- Variables `AWS_ACCOUNT_ID`, `AWS_REGION`, and `TF_STATE_BUCKET` from bootstrap.
- Existing bootstrap AWS credential secrets, with an optional session token.
- New secret **`DOMAIN_CONTACT_JSON`** with real contact information in this shape:

```json
{
  "first_name": "YOUR_FIRST_NAME",
  "last_name": "YOUR_LAST_NAME",
  "contact_type": "PERSON",
  "email": "YOUR_REACHABLE_EMAIL",
  "phone_number": "+49.YOUR_NUMBER",
  "address_line_1": "YOUR_STREET_AND_NUMBER",
  "city": "YOUR_CITY",
  "state": "YOUR_STATE_IF_REQUIRED",
  "country_code": "DE",
  "zip_code": "YOUR_POSTAL_CODE"
}
```

Administrative, technical and registrant contacts reuse this secret. Privacy is enabled
for all three. Contact values are sensitive in Terraform and individually masked in
Actions, but **remain in the encrypted Terraform state and saved plan**. No state or
plan is uploaded as a GitHub artifact. The app role has no access to registration state.

The bootstrap credentials must allow Route 53 Domains registration/management,
Route 53 zone/tag/record administration, ACM issuance/validation and state S3 access.
Normal infrastructure/app OIDC roles deliberately do not receive registrar permissions.
Registration uses the Route 53 Domains endpoint in `us-east-1`; ACM uses `AWS_REGION`,
which must be the ALB region.

Run **Actions → Infra CI/CD (select include-domain)**, initially with apply unchecked.
The first plan covers registration; TLS planning is deferred until the new zone exists.
Then manually run with apply checked and approve the bootstrap environment. That run
plans/applies registration, imports/tags its zone, and plans/applies ACM validation.
Answer any registrar verification email promptly; registration/DNS propagation may take
longer than one workflow run. If registration times out, check AWS operation status and
state before retrying; import an already-registered domain rather than purchase again.

Do not replace, delete or lose registration state. If you already registered the domain
outside Terraform, import it before applying this stack. Keep contact details and state
private. Domain ownership is not a secret: the name will appear in DNS and public
certificate transparency, even though APP_DOMAIN is stored as a GitHub secret.

## 2. Connect outputs to bootstrap and app deployment

The Infra CI/CD domain job summary provides the certificate ARN and hosted zone ID.

1. Set **`APP_HOSTED_ZONE_ID`** in `bootstrap` and run **Bootstrap Infra** with apply.
   This grants the app role permission to change only the A record
   `tasky.abu-pse.link` in that zone and use its isolated app-DNS state key.
2. In **`app-deployment`**, set secret **`APP_DOMAIN=tasky.abu-pse.link`**.
3. Set these `app-deployment` variables:

| Variable | Source |
| --- | --- |
| `AWS_ACCOUNT_ID`, `AWS_REGION`, `TF_STATE_BUCKET` | Bootstrap outputs/shared repository variables |
| `AWS_APP_DEPLOY_ROLE_ARN` | Bootstrap `github_variables` |
| `ACM_CERTIFICATE_ARN` | Domain workflow summary |
| `APP_HOSTED_ZONE_ID` | Domain workflow summary |
| `PUBLIC_SUBNET_IDS` | JSON array from infrastructure `public_subnet_ids` output |
| `EKS_CLUSTER_NAME` | Infrastructure output; defaults to `tasky-wiz` |

4. Prepare an **ephemeral self-hosted Linux runner** labelled `tasky-eks`, reachable
   from GitHub and able to reach the private EKS endpoint, with Docker, AWS CLI,
   Python 3, Helm and kubectl installed. No runner fleet is created by these stacks.
5. Complete the existing operator setup: AWS Load Balancer Controller with its IRSA
   role, the namespace/required cluster-admin exercise binding, `tasky-secrets`,
   and `tasky-mongo-ca`. See the bootstrap and Helm READMEs. If the GHCR package is
   private, configure a namespace image pull secret/SA before deployment; runner
   registry login does not grant image-pull access to EKS nodes.
6. Enable repository variable **`ENABLE_APP_DEPLOY=true`** once those prerequisites
   are ready. Restrict app-deployment to main and require reviewers.

After publish/sign succeeds, the app workflow verifies the digest's signature using
this repository's main-branch workflow identity, assumes the app role, generates Helm
values from APP_DOMAIN/certificate/subnets, and deploys. It waits for the Ingress ALB
and checks the HTTPS listener's certificate before applying the DNS alias stack.

The AWS Load Balancer Controller owns the ALB/listeners/target groups; Terraform does
not create a second ALB or competing listener. Helm configures 443 with ACM, redirects
80 to 443, and forwards HTTP to the non-root app. TLS terminates at the ALB. Registration
and validation CNAMEs are separate from the application's A alias; retain the validation
CNAME for certificate renewal. DNS updates occur on app deployment, including after
an ALB replacement, rather than through an additional ExternalDNS controller.

## Validation and cleanup

All stack tests use mocked providers; they do not register domains. The Infra CI/CD domain job
runs fmt/validate/tests before assuming credentials. Local verification:

```sh
# After terraform init -backend=false in each root:
terraform -chdir=infra/terraform/domain/registration test
terraform -chdir=infra/terraform/domain/tls test
terraform -chdir=infra/terraform/app-dns test
```

On cleanup, remove the app alias through the app-DNS state, then remove the app Ingress
and wait for the controller to delete its ALB before tearing down EKS. Preserve domain
registration/zone/state unless domain retirement is explicitly intended. Removing EKS
must not cancel ownership of `abu-pse.link`.

References: [Terraform domain registration](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53domains_domain),
[ACM DNS validation](https://docs.aws.amazon.com/acm/latest/userguide/dns-validation.html),
[ALB certificate annotation](https://kubernetes-sigs.github.io/aws-load-balancer-controller/v2.15/guide/ingress/annotations/).
