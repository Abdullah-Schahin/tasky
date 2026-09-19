# CI bootstrap

Run this stack through the manually triggered **Bootstrap AWS account** Actions workflow. It owns the GitHub OIDC provider
(or reuses one), four CI roles, the workload permissions boundary, and one private
S3 bucket for infrastructure state and saved plans. It does not create EKS, runners,
access keys, DynamoDB, or another application registry. All taggable resources receive
`created by=Abu` and `for=Wiz PSE` through provider default tags.

| Role | GitHub environment | Access |
| --- | --- | --- |
| `tasky-wiz-ci-plan` | None; exact `main` branch subject | Discovery metadata, read infrastructure state, write locks and plans |
| `tasky-wiz-ci-apply` | `infra-deplyoment` | Apply infrastructure, write state, read saved plans |
| `tasky-wiz-ci-publish` | None; main branch OIDC | Push/pull image and signing artifacts in the Tasky ECR repository only |
| `tasky-wiz-ci-app` | `app-deployment` | Describe the named cluster; infrastructure stack adds EKS admin in namespace `tasky` |

OIDC trusts match the exact, case-sensitive repository plus immutable owner/repository
IDs, environment and STS audience. This repository uses GitHub's immutable OIDC subject
format: `repo:OWNER@OWNER_ID/REPO@REPO_ID:environment:ENVIRONMENT`.
Actions supplies `GITHUB_REPOSITORY_OWNER_ID` and `GITHUB_REPOSITORY_ID` automatically;
do not create GitHub variables for them. Local bootstrap runs must supply the equivalent
Terraform inputs shown in `terraform.tfvars.example`. Rerun bootstrap apply to migrate
existing name-only trust policies. Repositories using legacy or customized subjects
must adapt this trust template to their actual OIDC subject before using these roles.
Normal deployment uses OIDC; initial bootstrap uses separately supplied AWS credentials.
Environment subjects do not themselves
restrict branches: configure **both deployment environments to allow only `main`**. Require
reviewers for `infra-deplyoment` and `app-deployment`, prevent self-review and disable bypass
where supported. These repository settings must be configured before enabling deployment.

The apply role is privileged within this dedicated sandbox/region: network creation
and account-level Config/GuardDuty/Security Hub operations require broad resource scope.
Named EKS, registry, logs, buckets, secrets and workload identities are scoped separately.
It cannot administer the bootstrap roles/provider/boundary or state bucket configuration.
Workload role creation requires the bootstrap-owned boundary, which prevents IAM
administration, role assumption and access to the state bucket. The state bucket also
explicitly denies the workload roles, including the deliberately excessive MongoDB role.
This is not a production multi-tenant isolation boundary; review IAM changes alongside
Terraform changes. Existing custom Secrets Manager/KMS inputs may require additional
narrow permissions; the defaults target the stack-managed MongoDB secret.

## Manual workflow setup

Create a GitHub environment named `bootstrap` (or one per account, such as
`bootstrap-sandbox`). Restrict deployments to **main**, require reviewers, and protect
its secrets. Use one bootstrap environment per target account/prefix so concurrent
first-run setup is serialized. The workflow also rejects other branches and never
cancels an in-progress bootstrap. It has no push or PR trigger.

Configure these environment variables (repository variables also work):

| GitHub variable | Required/default | Purpose |
| --- | --- | --- |
| `AWS_ACCOUNT_ID` | Required | Expected 12-digit target account; checked against credentials |
| `AWS_REGION` | Required | Target commercial AWS region, e.g. `us-east-1` |
| `BOOTSTRAP_PREFIX` | `tasky-wiz` | Must match the infrastructure stack prefix |
| `TF_STATE_KEY` | `infra/terraform.tfstate` | Infrastructure state path, always under `infra/` |
| `AWS_GITHUB_OIDC_PROVIDER_ARN` | Omit | Create this GitHub variable only to reuse an externally managed account-level GitHub OIDC provider; otherwise do not create it |

The repository identity comes from `github.repository`; no owner/repository variable
or hard-coded account ID is needed in the workflow. The state bucket name is derived
as `<prefix>-tfstate-<account>-<region>`.

Configure these **environment secrets**, never plain variables:

| GitHub secret | Purpose |
| --- | --- |
| `AWS_BOOTSTRAP_ACCESS_KEY_ID` | Credentials authorized to perform bootstrap |
| `AWS_BOOTSTRAP_SECRET_ACCESS_KEY` | Matching secret access key |
| `AWS_BOOTSTRAP_SESSION_TOKEN` | Required for temporary credentials; leave unset for an IAM access key |

Use short-lived credentials where possible, valid for the duration of the run, and
remove/rotate them after bootstrap. Do not use AWS root credentials. Bootstrap credentials
need to manage the named bucket and its objects/settings, the named CI roles/policies,
and the GitHub OIDC provider (unless reusing one). Normal CI roles cannot bootstrap
themselves. AWS/GitHub credentials are never written into tfvars, backend files or artifacts.

1. Open **Actions → Bootstrap AWS account → Run workflow** on `main`.
2. Select the environment containing that account's configuration.
3. Leave `apply` unchecked to inspect the plan. **First-run plan mode still creates,
   secures and imports the state bucket**; the remaining bootstrap resources are only planned.
4. Review the Terraform plan in the logs and resource actions in the job summary.
5. Run again with `apply` checked. After environment approval, that run plans and applies
   its own exact saved plan. It does not reuse the plan from a previous run; review the
   commit/configuration before approving the run. Deletes/replacements are blocked.
6. Copy the resulting non-secret `github_variables` and `infrastructure_inputs` from
   the job summary into the deployment environment/repository configuration below.
   The workflow does not receive a GitHub administration token or edit GitHub settings.

No bootstrap workflow has been executed against AWS as part of implementation.

## Durable state and reruns

The workflow initializes the **same private bucket** owned by this Terraform stack;
it does not add another bucket or a DynamoDB table. Before any state write it enables
versioning, SSE-S3, all public access blocks, TLS enforcement, bucket-owner ownership,
and a deny for exercise workload roles. The bucket gets the required tags plus
`BootstrapState=true`, is imported into Terraform, and retains `prevent_destroy`.

Bootstrap state lives at **`bootstrap/terraform.tfstate`**, separate from infrastructure
state at `infra/terraform.tfstate`. Native S3 locking protects both. Subsequent runs load
that state, verify storage protections, and plan changes. State and plan files are never
uploaded as GitHub artifacts. Terraform updates state remotely even after a partial apply,
so retry with the same account/prefix. State versions have no automatic expiry.

An existing bucket must have matching ownership tags. A bucket whose bootstrap state is
missing while CI roles already exist is rejected: restore/migrate the state first. If a
first run fails between bucket creation and tagging, inspect the bucket and complete the
expected tags manually before retrying. Permissions/403 errors never trigger bucket creation.
A drifted public/unversioned bucket is rejected for manual recovery rather than used for state.

For a new account, choose its GitHub environment and supply fresh credentials. For an
existing account, preserve the same prefix and state. This workflow is not a destroy/reset
button; destructive teardown or lost-state recovery requires separate review.

## Moving an existing local bootstrap to Actions

If you already applied locally, do not start a fresh bootstrap state. With the matching
local tfvars, add `BootstrapState=true` to the existing bucket through a reviewed local
Terraform apply, then add an S3 backend block (the ignored `backend.ci.tf` filename is
available for this) and migrate the local state:

```sh
export AWS_PROFILE=wiz
# backend.hcl must point to the existing bucket, with key="bootstrap/terraform.tfstate",
# encrypt=true, use_lockfile=true and the expected region/account.
terraform -chdir=infra/terraform/bootstrap init -migrate-state -backend-config=/path/to/backend.hcl
```

Keep an encrypted backup of the original state and verify migration before running Actions.
Fresh local-only bootstrap is still supported using `terraform.tfvars.example` and the
local backend; Actions generates its backend file only on the runner.

Copy the `infrastructure_inputs` output into `infra/terraform/platform/terraform.tfvars` for local
runs and into GitHub `TFVARS_JSON` for CI. These are ARNs, not credentials. The
`backend_config` Terraform output is for **infrastructure**, with the `infra/` state key;
do not use it as the bootstrap backend. Existing local infrastructure state also requires
`init -migrate-state` to the private bucket, keeping the two state files separate.

## GitHub configuration

Set repository variables from `github_variables`. Also set `TFVARS_JSON` to the complete
non-secret infrastructure inputs (including the boundary ARN, app role ARN and SSH
**public** key). Never put database passwords or private keys in this variable.
Set `ENABLE_INFRA_DEPLOY=true` only after configuring the environments above.

Infrastructure CI validates the infrastructure stack; PRs scan without AWS credentials.
The separate manual bootstrap workflow validates/tests bootstrap before authenticating. Main runs
plan without an environment approval; manual dispatch with `apply=true` applies the exact saved
plan after `infra-deplyoment` approval, which is requested only after planning completes. Plans are stored in the private state bucket,
not public GitHub artifacts. The summary lists resource actions, with deletions/replacements first. Approval authorizes
all actions in that saved plan, including destructive changes; other security checks remain enforced.
Bootstrap IAM permissions are checked by mocked Terraform tests in CI; an AWS plan
validates API reads but is not proof that every create/update API will be authorized.

The app workflow publishes to the Terraform-created private ECR repository and has an opt-in AWS deployment job using
`app-deployment`. It can describe the cluster and ALB, but cannot write DNS or read
Terraform state. See [HTTP demo setup](../../http-demo.md) for app variables and the
intentional public TLS weakness. Infrastructure roles retain ACM read/delete access
only for removing the retired certificate; certificate creation is no longer granted.

When migrating from the previous environment names, create `infra-deplyoment` and
`app-deployment` first and copy their variables/secrets. Put
`AWS_TF_PLAN_ROLE_ARN`, `AWS_ACCOUNT_ID`, `AWS_REGION`, `TF_STATE_BUCKET`,
`TF_STATE_KEY`, `TFVARS_JSON`, and `ENABLE_INFRA_DEPLOY` in repository Actions variables.
Keep `AWS_TF_APPLY_ROLE_ARN` in `infra-deplyoment` (or repository variables).
Rerun Bootstrap Infra with apply enabled to update the OIDC trust policies before
running deployments. The role names and Terraform state keys remain unchanged.
Only Apply uses the protected environment. The plan role trusts the exact immutable
repository subject ending in `:ref:refs/heads/main`; the apply role trusts only
`:environment:infra-deplyoment`. Require reviewers and main-only deployment branches
on that environment. Push runs and manual runs without `apply` only plan.
For this migration, apply Bootstrap first to update plan-role trust, then run Infra CI/CD.

The runner needs private network connectivity to the EKS API. An ordinary GitHub-hosted
runner cannot reach the private endpoint by default; the platform stack creates a dedicated private deployment runner; see [runner setup](../platform/RUNNER.md).

## One-time cluster setup by an operator

Namespace-scoped app CI cannot create namespaces or the required exercise
ClusterRoleBinding. Before the first CI Helm installation, render the chart with real
AWS values and apply only these two templates using the operator context:

```sh
helm template tasky infra/helm/tasky -n tasky -f /path/to/real-aws-values.yaml \
  --show-only templates/namespace.yaml --show-only templates/clusterrolebinding.yaml |
  kubectl apply -f -
```

Then use `clusterResources.create=false` for app deployments; the operator owns those
objects. Local Minikube retains `true`, preserving its setup. If migrating an existing
Helm release, first upgrade with `true` to install the `keep` annotations, then switch
to `false`. Kept objects require explicit operator cleanup.

**Exercise caveat:** namespace administration permits deploying pods using Tasky's
intentionally cluster-admin service account. The app CI role therefore has an indirect
path to cluster admin in this exercise, despite its namespace-scoped EKS access. Only
trusted, approved app deployments should use it. Removing that binding closes this
intentional escalation path in a production setup.

## Validation

```sh
terraform -chdir=infra/terraform/bootstrap fmt -check -recursive
terraform -chdir=infra/terraform/bootstrap test
```

The tests use a mocked AWS provider; their `apply` commands create no AWS resources.
They check exact OIDC subjects, state protection, plan/app separation, MongoDB state
exclusion, mandatory boundaries, and reuse of existing OIDC providers.

References: [GitHub OIDC trust](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_create_for-idp_oidc.html),
[S3 backend and lock permissions](https://developer.hashicorp.com/terraform/language/backend/s3),
[EKS access scopes](https://docs.aws.amazon.com/eks/latest/userguide/access-policy-permissions.html).

## ECR publishing

After applying bootstrap, set repository variables `AWS_ECR_PUBLISH_ROLE_ARN` and
`ECR_REPOSITORY` from `github_variables`. No additional GitHub environment is needed.
The publisher trusts the immutable repository identity on main and has ECR push/pull
permissions only. The existing app role receives pull-only ECR access for Cosign
verification. The EKS node role already has AmazonEC2ContainerRegistryPullOnly.
