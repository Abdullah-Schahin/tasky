# HTTP-only demo: expected security weakness

Tasky deliberately exposes HTTP on port 80 of its public AWS ALB, using the
AWS-generated hostname. No custom domain, ACM certificate, HTTPS listener or
HTTP-to-HTTPS redirect is required. The ingress has no host restriction.

**Finding: sensitive application traffic transmitted without TLS.** This is an
intentional exercise misconfiguration, not a production recommendation. An attacker
on the network path could read passwords, session tokens and task data, or modify
responses in transit. Session-token theft could enable account takeover. Use only
synthetic demo accounts and data. Missing a custom domain is not itself the weakness;
the missing transport encryption and server authentication are the weakness.

## Deployment

1. Push these changes. Run and approve Bootstrap Infra to update IAM permissions.
2. Run and review the infrastructure plan. It may delete exactly the retired
   `aws_acm_certificate.app` for `tasky-abu-pse.apps.dj`. The job summary lists all
   deletions/replacements; approving Apply authorizes the complete saved plan.
   Apply after review. If an older deployment already attaches that certificate to
   an ALB, deploy the HTTP-only Helm change first to detach it, then apply Terraform.
3. Configure environment `app-deployment` with required reviewers and main-only access.
   Its variables are `AWS_APP_DEPLOY_ROLE_ARN`, `EKS_CLUSTER_NAME`, and
   `PUBLIC_SUBNET_IDS` (JSON array). Repository variables remain `AWS_ACCOUNT_ID`,
   `AWS_REGION`, and `ENABLE_APP_DEPLOY`. No app environment secrets are required
   for DNS/TLS; remove obsolete `APP_DOMAIN` and `ACM_CERTIFICATE_ARN` settings.
4. Ensure the private EKS runner, Load Balancer Controller, namespace and exercise
   cluster RBAC, `tasky-secrets`, and `tasky-mongo-ca` are ready. The EKS node IAM role supplies ECR pull permissions. MongoDB continues to require TLS.
5. Set repository variable `ENABLE_APP_DEPLOY=true`, run App CI/CD on main, and
   approve Deploy App. The job summary reports `http://<AWS-generated-ALB-hostname>`.

You can also obtain the address with:

```sh
kubectl -n tasky get ingress tasky -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

Use `http://` explicitly. Browsers may try HTTPS automatically; no HTTPS listener
is configured. ALB replacement can change this hostname.

## Evidence and remediation

- Inspect ingress annotations: HTTP listener on port 80, no certificate or redirect.
- Confirm the public ALB has an HTTP listener and no HTTPS listener.
- Access a synthetic test account via the HTTP URL; record the browser's insecure
  connection indicator without capturing real credentials or session tokens.
- Expected impact: loss of confidentiality and integrity for client-to-ALB traffic.
- Remediation: obtain a hostname with DNS control, issue/attach an ACM certificate,
  enable HTTPS on 443, redirect HTTP to HTTPS, and use Secure session cookies.

ACM discovery/deletion permission remains on the infrastructure roles solely to
retire the existing certificate. App CI has no ACM permissions. No FreeDNS record
is changed or required, and existing Terraform state must be retained.
