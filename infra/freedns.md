# FreeDNS and HTTPS for Tasky

The demo hostname is `tasky-abu-pse.apps.dj`. FreeDNS manages DNS; Terraform does not
register a domain or require a Route 53 zone. The platform requests an ACM certificate
in the ALB region, but does not wait for manual DNS validation during infrastructure apply.

## Setup order

1. Push these changes and rerun **Bootstrap Infra** with apply enabled. This grants the
   infrastructure roles ACM permissions and gives the app role certificate/ALB read access.
2. Run **Infra CI/CD** with apply enabled. The old `include-domain` option is removed.
3. Copy the `app_tls` output / workflow summary. In FreeDNS add a **CNAME** using the
   exact validation record name and target from ACM. This is a separate record beneath
   your hostname, such as `_token.tasky-abu-pse.apps.dj`; do not overwrite the app record.
   If FreeDNS appends `apps.dj`, enter the name without that suffix. Confirm the resulting
   fully qualified name exactly matches ACM. Keep this record for certificate renewal.
4. Wait until ACM status is **ISSUED**. If FreeDNS disallows the underscore-prefixed
   record or CNAME type for this shared domain, certificate validation cannot complete;
   confirm support with FreeDNS/the domain owner before enabling app deployment.
5. Configure `app-deployment` with:

   | Setting | Kind | Value |
   | --- | --- | --- |
   | `APP_DOMAIN` | Secret | `tasky-abu-pse.apps.dj` |
   | `ACM_CERTIFICATE_ARN` | Variable | Platform `app_tls.certificate_arn` |
   | `AWS_APP_DEPLOY_ROLE_ARN` | Variable | Bootstrap app role |
   | `EKS_CLUSTER_NAME` | Variable | Platform cluster name |
   | `PUBLIC_SUBNET_IDS` | Variable | Platform public subnet IDs as a JSON array |

   Keep shared repository variables `AWS_ACCOUNT_ID` and `AWS_REGION`. Set repository
   variable `ENABLE_APP_DEPLOY=true` only after the cluster/controller/runner and
   Kubernetes secrets are ready. Require reviewers and main-only deployments.
6. Run App CI/CD on main and approve Deploy App. It requires an issued certificate,
   installs Helm and checks the ALB HTTPS listener. The job summary gives the app
   CNAME target: the ALB hostname, with no scheme or path.
7. Edit your FreeDNS `tasky-abu-pse.apps.dj` record to type **CNAME** with that target.
   Replace any conflicting A/AAAA record at that same name. Do not use URL forwarding
   or a fixed ALB IP. After DNS propagation, open `https://tasky-abu-pse.apps.dj`.

No FreeDNS credentials are stored in GitHub and no FreeDNS records are changed by CI.
If the ALB is replaced, update its CNAME target using the new deployment summary.
The script confirms ALB readiness, not external DNS propagation.

Remove obsolete `DOMAIN_CONTACT_JSON` and `APP_HOSTED_ZONE_ID` GitHub settings.
`TF_STATE_BUCKET` is still required by infrastructure CI, but not app deployment.
If bootstrap previously granted the optional Route 53 app policy, its removal is an
IAM policy deletion; the bootstrap deletion guard will require a reviewed migration.
Do not disable the guard globally.

Existing prerequisites remain: a runner labeled `self-hosted`, `linux`, `tasky-eks`
with private EKS connectivity; AWS Load Balancer Controller; operator-created namespace
and exercise cluster RBAC; `tasky-secrets` and `tasky-mongo-ca` Kubernetes secrets; and
image pull credentials if GHCR is private.

AWS documents [external DNS validation](https://docs.aws.amazon.com/acm/latest/userguide/dns-validation.html).
