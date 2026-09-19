# Tasky Wiz PSE AWS exercise

Terraform for the isolated exercise account. This deliberately exposes SSH and database
backups, while keeping MongoDB authenticated, TLS-only, and reachable only from the
private EKS node security group. Use synthetic exercise data only.

## Architecture and resource choices

```text
Internet -> ALB (created by AWS Load Balancer Controller) -> Ingress -> Tasky
                                                               private EKS nodes
                                                                      |
                                                                  TCP 27017/TLS
                                                                      |
Internet -> SSH 22 -> MongoDB EC2 in public subnet <--------------------+
                           |
                  systemd daily mongodump -> public-read/list S3 backups

EKS API/audit/authenticator/controller logs -> CloudWatch
AWS management events -> existing organization CloudTrail (or optional new trail)
AWS Config -> selected resource types + three managed rules -> private audit S3
```

Two public and two private subnets span two AZs. One NAT gateway supplies outbound
access for both private subnets; this cost-conscious lab choice is not multi-AZ NAT
resilience. EKS nodes have no public IPs. The MongoDB instance has a public IP solely
for the required SSH path; its database ingress references the EKS node security group,
never a public CIDR. The default EKS API is private-only. Setting operator `/32` CIDRs
adds a restricted public API endpoint without moving the cluster ENIs or nodes.

Terraform creates only the app's VPC/routes/NAT, EKS with two workers, ECR, MongoDB
instance and credentials/key-pair, backup bucket, private audit destination, necessary
IAM and security groups, AWS Config. Security Hub CSPM (default standards) and GuardDuty are
**enabled by default**. There is no Terraform-created ALB, Route 53 zone,
extra bastion, standalone guardrail demo bucket, VPC endpoint fleet, or redundant audit services. CI bootstrap is maintained separately in `../bootstrap`.
The existing secure audit bucket also serves as the separate preventive-control example.

The controller's IAM policy is vendored verbatim from the official
[v2.14.1 policy](https://github.com/kubernetes-sigs/aws-load-balancer-controller/blob/v2.14.1/docs/install/iam_policy.json).
Terraform provisions its OIDC trust/role; install the matching controller separately
after the cluster is reachable. This avoids Kubernetes/Helm provider bootstrapping
against a cluster that does not yet exist. Application manifests live in `infra/helm`.

## Sandbox inspection (2026-09-18)

Read-only checks used profile `wiz`, account `516027198761`, region `us-east-1`:

- No VPCs, EC2 instances or EKS clusters in the target region.
- Six standard AZs available; the example selects `us-east-1a` and `us-east-1b`.
- No AWS Config recorder/channel or GuardDuty detector. Security Hub is not subscribed.
- No account-level S3 Public Access Block configuration was returned. Bucket-level
  public access is still subject to any organization policies enforced at apply time.
- Organization trail `management-events-lab`, owned by account `525391386877`, is logging
  and has a management-event selector, multi-region coverage and global-service events enabled. The example reuses its ARN without managing it.
- Official Canonical Ubuntu 20.04 AMI `ami-0fb0b230890ccd1e6` was available in this region,
  created 2025-06-25. The active/old Ubuntu 22.04 searches returned no candidates.

API read access does not prove permission to create resources. Service quotas, IAM/SCP
restrictions, instance capacity, package availability and optional service enrollment
still need apply-time verification. Do not assume Organizations administration is
available. `preflight.py` inventories existing services without fetching secret values:

```sh
python3 .github/scripts/aws-preflight.py --profile wiz --region us-east-1 \
  --account-id 516027198761
```

Stop if a required service is denied. Do not weaken unrelated account-level controls
to force deployment. For optional services, leave their booleans false unless supported.
Terraform cannot catch `AccessDenied` and silently continue: disable an unsupported
optional service before planning. If Config is unavailable, choose a permitted detective
service explicitly and document the limitation. Existing Config/GuardDuty/Hub resources
must be imported or reused deliberately instead of creating a competing account setup.

## Tags

AWS provider `default_tags` applies **`created by = Abu`**, **`for = Wiz PSE`**, and
`Project = tasky-wiz` to every taggable Terraform resource. Launch-template tag
specifications propagate tags to worker instances, volumes and network interfaces.
Explicit tag resources cover the EKS-created security group and node autoscaling group.
The Helm Ingress and controller values below also tag controller-created AWS resources.

AWS has no tag API for some objects, including route associations, IAM policy attachments,
Config recorder/channel, bucket policies/settings, secret versions, EKS access-policy
associations, and Security Hub account enrollment. Their owning resources carry the tags;
Terraform cannot attach unsupported `tags` arguments to these child configurations.

## Local preparation and plan

Requires Terraform >=1.11, AWS CLI, an authorized sandbox profile, Helm, and kubectl.
The provider lockfile pins tested providers. No AWS keys are embedded in Terraform.

A dedicated SSH key was generated at `.local/tasky-wiz/mongodb`; its public counterpart
is `.local/tasky-wiz/mongodb.pub`. Both are excluded from Git. The private key is mode
0600 in a mode-0700 directory. Keep it locally; only the public key enters Terraform.
The local ignored `terraform.tfvars` is populated for this inspected account.
For a fresh checkout, generate a new key and copy/edit the example instead:

```sh
mkdir -p .local/tasky-wiz
chmod 700 .local/tasky-wiz
# Do not overwrite an existing key used by a deployed instance.
ssh-keygen -t ed25519 -f .local/tasky-wiz/mongodb -C tasky-wiz-mongodb
cp infra/terraform/platform/terraform.tfvars.example infra/terraform/platform/terraform.tfvars
chmod 600 infra/terraform/platform/terraform.tfvars
# Set ssh_public_key to the .pub contents and verify every sandbox-specific value.
export AWS_PROFILE=wiz
terraform -chdir=infra/terraform/platform init -backend-config=../../../.local/tasky-wiz/backend.hcl
terraform -chdir=infra/terraform/platform fmt -check
terraform -chdir=infra/terraform/platform validate
terraform -chdir=infra/terraform/platform plan -out=tasky.tfplan
terraform -chdir=infra/terraform/platform show tasky.tfplan
terraform -chdir=infra/terraform/platform show -json tasky.tfplan > /tmp/tasky-plan.json
python3 .github/scripts/terraform-plan-check.py /tmp/tasky-plan.json
# Apply only after reviewing the concrete plan and sandbox costs/permissions.
terraform -chdir=infra/terraform/platform apply tasky.tfplan
```

State, plans, `.terraform`, private keys and `.tfvars` are ignored. Keep the lockfile in
Git. First follow [the bootstrap instructions](../bootstrap/README.md) to create private
state storage. For local commands, write `.local/tasky-wiz/backend.hcl` using the
bucket, region and `infra/` key from the bootstrap summary, with `encrypt=true`,
`use_lockfile=true` and `allowed_account_ids=["<your-account-id>"]`. Set the boundary and app role
inputs from the bootstrap outputs. Existing local state must be migrated using
`terraform init -migrate-state` with that backend configuration, not discarded.

## MongoDB and credentials

MongoDB server **6.0.16** is explicitly pinned and held. The Ubuntu AMI is pinned and a
plan precondition requires its creation date to be older than one year. Bootstrap does
not upgrade the OS/kernel, and disables unattended upgrade timers for this documented
exercise exception. Only prerequisite packages, tools and the chosen MongoDB server are
installed. If old package repositories stop serving the version, bootstrap must fail;
do not silently substitute a recent server. Use a verified pre-baked old AMI as the
explicit alternative after reviewing it.

By default Terraform creates one Secrets Manager secret with three 32-character
passwords: `admin_password`, `app_password`, `backup_password`. Ephemeral random values
are passed to the provider's write-only secret version field, avoiding plaintext
passwords in state or plan. To reuse credentials, set `mongodb_secret_arn` instead;
existing JSON values must have these same keys with at least 24 characters each.
Secrets Manager uses its managed encryption key unless a custom key ARN is supplied.

EC2 fetches this secret at boot using IMDSv2 and the instance role. Temporary root-only
credential/init files are removed after initialization. MongoDB has separate admin,
application (`readWrite` on `go-mongodb`) and backup identities. The backup password is
stored in a root-only local `mongodump` config file, not command-line arguments.
Do not independently rotate Secret values: update MongoDB users, local backup config
and the application's Kubernetes Secret in a coordinated rotation.

Bootstrap generates a dedicated 90-day lab CA and server certificate with the private
IP in its SAN. MongoDB requires TLS and password authentication. The CA certificate is
public trust material; the CA/server private keys remain on the MongoDB host. Plan
certificate renewal if the lab survives longer than 90 days.

The systemd timer runs daily at 02:00 UTC (up to five minutes jitter), and a first backup
runs during bootstrap. Dumps use TLS, compression and SSE-S3 uploads under `daily/`.
Local temporary archives are removed. Backups intentionally become public-readable.
Replacing/destroying the VM removes its root-disk database, so rehearse restore from
backups before replacement. A Terraform apply succeeding is not proof cloud-init or
the first backup succeeded; use the checks below.

## Connect EKS, install controller, deploy the app

First provision and register the [private deployment runner](RUNNER.md). It supplies
the existing app workflow with private EKS connectivity; no public EKS endpoint is needed.

The private API requires a network path into the VPC (existing VPN/tunnel/runner), or
set `eks_public_access_cidrs` to your current public IPv4 `/32`, replan and review.
No public `0.0.0.0/0` EKS API access is accepted.

```sh
aws eks update-kubeconfig --profile wiz --region us-east-1 --name tasky-wiz
kubectl get nodes -o wide
```

Install AWS Load Balancer Controller using its official Helm chart, matching the
vendored IAM policy to controller v2.14.1 (update both together when upgrading). Supply
these values; render/review them and install in `kube-system`:

```yaml
clusterName: tasky-wiz
region: us-east-1
vpcId: REPLACE_WITH_VPC_OUTPUT
serviceAccount:
  create: true
  name: aws-load-balancer-controller
  annotations:
    eks.amazonaws.com/role-arn: REPLACE_WITH_CONTROLLER_ROLE_OUTPUT
defaultTags:
  created by: Abu
  for: Wiz PSE
```

Explicit region/VPC values avoid controller reliance on pod IMDS access. The workers'
IMDS hop limit is one. EKS VPC CNI provides routable pod IPs and controller IP targets.
Create the Helm namespace and Secrets using the instructions in `infra/helm/README.md`.
Copy the MongoDB CA into a local public file, then its Kubernetes Secret:

```sh
# MONGO_IP is terraform output -raw mongodb_public_ip.
ssh -i .local/tasky-wiz/mongodb ubuntu@"$MONGO_IP" \
  'sudo cat /etc/mongodb/tls/ca.crt' > .local/tasky-wiz/ca.crt
kubectl -n tasky create secret generic tasky-mongo-ca \
  --from-file=ca.crt=.local/tasky-wiz/ca.crt --dry-run=client -o yaml | kubectl apply -f -
terraform -chdir=infra/terraform/platform output -raw helm_aws_values > .local/tasky-wiz/values-aws.yaml
```

Set the existing `tasky-secrets` `MONGODB_URI` to the `mongodb_tls_uri_template` output,
replacing its password placeholder with the **URL-encoded app password** retrieved
securely from Secrets Manager. Keep `SECRET_KEY` separately generated. Do not put
credentials on the command line, in Helm values, screenshots or logs. The app currently
logs its MongoDB URI at startup; avoid exposing those logs until separately corrected.
The chart's optional `mongodbTLS.existingSecret: tasky-mongo-ca` mounts the trust file
at `/etc/tasky-mongo-tls/ca.crt`. Local Minikube leaves this feature disabled.

The app intentionally uses HTTP on the AWS-generated ALB hostname. No DNS validation
or certificate is required. See [HTTP demo setup and remediation](../../http-demo.md).
App CI publishes signed images and attestations to this stack's ECR repository.
EKS pulls by immutable digest using the node role's ECR pull permissions.

## Findings, controls and production changes

| Resource | Current state | Intentional? | Production recommendation |
| --- | --- | --- | --- |
| MongoDB EC2 | Ubuntu 20.04 AMI dated 2025-06; updates held | Yes | Supported patched OS with automated patching |
| EC2 SSH | Internet TCP/22; key-only auth, no root login | Yes | SSM Session Manager; no public ingress |
| MongoDB | Server 6.0.16 | Yes | Supported patched server release |
| EC2 IAM | EC2 lifecycle/discovery and account-wide S3 data access | Yes | Backup-prefix upload + specific credential access only |
| Backup S3 | Anonymous ListBucket/GetObject | Yes | Private bucket, public access block |
| Backup S3 | No versioning | Yes | Versioning and retention/restore policy |
| Backup S3 | Default SSE-S3, no encryption-enforcement bucket policy | Yes | Enforced encryption policy and approved KMS key |
| VPC | No Flow Logs | Yes | Centralized network telemetry |
| EKS | Private nodes, API CIDR restrictions, all five control-plane log types | Secure baseline | Retain and improve operational resilience |
| MongoDB network | SG-to-SG TCP/27017, TLS and distinct users | Secure baseline | Retain and use managed certificate lifecycle |
| Audit S3 | Public access blocked, versioned, SSE-S3, deny non-TLS | Preventive control | Centralized immutable audit storage |
| AWS Config | Public S3, unrestricted SSH and versioning rules | Detective control | Broader continuous configuration coverage |
| Security Hub / GuardDuty | Enabled in platform configuration | Detection/posture | Review findings after approved apply |
| Public app ingress | HTTP-only ALB, no TLS | Yes | Controlled hostname, ACM, HTTPS and HTTP redirect |
| App service account | Existing Helm cluster-admin/token/PSA exercise gaps | Yes | Least-privilege RBAC and workload guardrails |

The IAM attack path is realistic privilege creep, not AdministratorAccess: compromise
of the VM can affect EC2 lifecycle and S3 data in this account. It does **not** receive
IAM writes, `iam:PassRole`, unrestricted Secrets Manager access or AdministratorAccess.
Config's encryption-enabled rule alone would not flag missing encryption-policy
enforcement because SSE-S3 still encrypts objects; discuss these controls separately.

The preventive example uses the already-needed **audit bucket**, not an extra demo
resource: all public-access blocking is on, and an explicit bucket-policy Deny rejects
insecure transport even when an identity policy allows the operation. This leaves the
exercise backup bucket's public read/list exception intact. Demonstrate the Deny through
policy inspection/IAM simulation or an authorized HTTP request, without making audit
objects public. Config detects; the S3 policy prevents—these are different controls.

## Post-apply validation and evidence

Do not claim these checks passed based on `terraform validate` or `plan` alone.

1. **Networking/EKS:** inspect node EC2 subnet IDs, routes, public-IP fields, and
   `kubectl get nodes -o wide`. Both worker subnets must route outward through NAT,
   not an IGW. Inspect the controller-created ALB scheme and public subnet IDs.
2. **Mongo bootstrap:** SSH using the dedicated key; run `sudo cloud-init status --wait`,
   `cat /etc/os-release`, `uname -r`, `mongod --version`, `sudo systemctl status mongod`,
   and `sudo test -f /var/lib/tasky-backup/bootstrap-complete`. Inspect logs locally;
   do not publish credentials. Test an authenticated TLS connection from an EKS pod.
   A test from outside the VPC to the public IP on 27017 must fail, while 22 is reachable.
3. **Backup:** `sudo systemctl list-timers tasky-mongo-backup.timer` and
   `sudo systemctl start tasky-mongo-backup.service`; inspect successful delivery. Use
   `aws s3api list-objects-v2 --bucket "$BACKUP_BUCKET" --no-sign-request` and anonymously
   GET a known *synthetic* backup to verify public list/read. No anonymous PutObject
   permission is granted. Delete downloaded test data locally after inspection.
4. **Application:** create a uniquely named todo, refresh it, and query its matching
   document in `go-mongodb.todos` using an authenticated DBMS/TLS connection. Preserve
   UI and document evidence. Do not reuse the local `todo-roundtrip.js` unchanged: it
   expects an in-cluster MongoDB pod, which this AWS architecture does not deploy.
5. **Audit:** inspect CloudTrail trail status/selectors and recent events. Confirm EKS
   `enabledClusterLogTypes`, then inspect `/aws/eks/tasky-wiz/cluster` in CloudWatch.
6. **Detective controls:** check Config recorder status and rule evaluation results
   after recording settles. Expect public-S3, open-SSH and backup-versioning findings.
   After apply, verify Hub/GuardDuty enrollment and actual findings independently.
7. **Preventive control:** inspect secure audit bucket settings and explicit TLS Deny.
   Check that the backup bucket still permits its intended anonymous reads/listing.
8. **Tags:** inspect taggable resources and controller-created ALB/target groups for
   `created by=Abu` and `for=Wiz PSE`. Policy attachments/settings do not support tags.

Useful outputs: VPC/subnets, cluster name/endpoint, region, ECR URL, Mongo private/public
IP and SSH command, Secret ARN (not passwords), backup/audit bucket names, CloudTrail
ARN, controller IAM role, service toggles, and non-secret Helm AWS values.

## Cleanup

Delete the app Ingress and wait for the controller to remove ALB/target groups first.
Remove the controller Helm release before deleting EKS. Review `terraform plan -destroy`
before any teardown. Buckets and ECR deliberately have `force_destroy/force_delete=false`:
empty demo backups, audit object versions/delete markers, and images only after deciding
what evidence to retain. Secrets have a seven-day recovery window. Reused organization
CloudTrail is not owned by this stack and will not be deleted. Retain remote state and the separate bootstrap state until
cleanup is complete. NAT, EKS, nodes, public IPv4, logs, Config and storage incur charges.

## Primary references

- [EKS networking requirements](https://docs.aws.amazon.com/eks/latest/userguide/network-reqs.html)
- [MongoDB Ubuntu installation and exact-version packages](https://www.mongodb.com/docs/manual/tutorial/install-mongodb-on-ubuntu/)
- [S3 Block Public Access](https://docs.aws.amazon.com/AmazonS3/latest/userguide/access-control-block-public-access.html)
- [AWS Config managed rules](https://docs.aws.amazon.com/config/latest/developerguide/managed-rules-by-trigger-type.html)
- [Terraform write-only arguments](https://developer.hashicorp.com/terraform/language/resources/ephemeral/write-only)
