# CI/CD and reusable security scans

`app-ci-cd.yaml` owns app build, Minikube tests, container build/evidence, and publishing.
`security-scans.yaml` is a reusable `workflow_call` workflow owning scanner execution,
report artifacts, per-scanner PR comments, and the selected-scanner failure gate.
PR comments run in isolated jobs in the same workflow without checking out or executing
repository code. The four comment jobs share their steps through a YAML anchor.

The app calls security scans twice:

1. `source-security` after Minikube tests: TruffleHog, Bearer, and govulncheck.
2. `image-security` after container build: Trivy against the uploaded image archive.

Container building waits for source scans; publishing/signing waits for the image scan.
The image is built once for release. Its archive checksum is checked by both Trivy's job
and publishing. SBOM/provenance are generated alongside the candidate archive before
scanning; nothing is pushed or signed unless the security gates pass. The Minikube test
builds a separate development image from the same checkout.

## Plug scanning into another pipeline

Call the shared workflow as a job, not a step:

```yaml
jobs:
  security:
    uses: ./.github/workflows/security-scans.yaml
    permissions:
      contents: read
      actions: read
      pull-requests: write
    with:
      report-prefix: terraform
      trufflehog: true
      working-directory: infra/terraform/platform
```

This example enables secret scanning only; it does not claim to scan Terraform
misconfigurations. Add future Terraform/Kubernetes scanners to `security-scans.yaml`,
the selected-scanner gate, and the shared report formatter/reporter. Their calling
pipelines can then opt in without copying scanner implementations. Those CI/CD workflows
do not exist yet in the current repository.

| Input | Default | Purpose |
| --- | --- | --- |
| `report-prefix` | Required | Unique lowercase name per call in a run, e.g. `app-source`, `app-image`, `terraform`, `kubernetes` |
| `trufflehog`, `bearer`, `govulncheck`, `trivy` | `false` | Select scanners; at least one must be enabled |
| `working-directory` | `.` | Bearer and govulncheck scan path; TruffleHog scans the Git commit range |
| `image-artifact-id` | Empty | Required by Trivy; artifact in this run containing `tasky-image.tar` |
| `image-sha256` | Empty | Required by Trivy; expected SHA256 of the archive |
| `trivy-severity` | `CRITICAL` | Blocking container vulnerability severities |
| `comment-on-pr` | `true` | Post per-scanner comments on same-repository PRs |

Each selected scanner must succeed. Disabled scanners may skip; a selected scanner
that fails, is cancelled, or skips fails the final gate. Bearer retains the exercise's
advisory `exit-code: 0` policy. No secrets inheritance is needed. The caller grants the
permission ceiling shown above; scanner jobs explicitly restrict their own permissions
to read-only. Only isolated comment jobs request PR write permission.

## Reports and fork PRs

Each scanner's comment job starts when that scanner completes, including failure; it
does not wait for the other scanners or pipeline stages. Reports include outcome,
rule/detector IDs, locations or modules, and a workflow link. Artifact names and comment
markers include `report-prefix` to avoid collisions between calls in the same run.
There is one comment per prefix/scanner/run, updated on reruns.

TruffleHog raw output is temporarily captured and deleted after summary generation.
Only detector, verification status and file/line metadata are published, never Raw,
RawV2, Redacted, ExtraData, or source snippets. Missing reports produce a fallback
status comment. Summaries show up to 50 findings; Bearer/Trivy SARIF and govulncheck JSON
remain available as artifacts. Fork PRs get summaries/artifacts without PR comments;
no elevated `pull_request_target` workflow is used.

## Minikube test

The app test starts an isolated `tasky-ci` profile on Ubuntu 24.04 and invokes
`infra/local/deploy-minikube.py`. It runs `tests/todo-roundtrip.js` via `mongosh` in
the MongoDB pod. Deployment/test failures block subsequent stages and cleanup always
runs. The test covers API/database CRUD and reload persistence, not browser or ingress
behavior. Infrastructure changes also trigger the app pipeline.

## Validation and required checks

```sh
terraform -chdir=infra/terraform fmt -check -recursive
```

Reusable jobs change the displayed check names. Update branch protection/rulesets to
require the appropriate `Source security` and `Image security` nested gate checks after
the first GitHub run. Local validation does not post comments or trigger workflows.

## Manual AWS bootstrap

`infra-bootstrap.yaml` runs only through **Run workflow** on `main`. Select the account's
GitHub environment and choose plan or apply. Account/region/prefix come from variables;
initial AWS credentials come from environment secrets. It initializes private S3 state
on the first run, retains it for subsequent runs, and blocks deletes/replacements.
See [bootstrap setup](../../infra/terraform/bootstrap/README.md) for the exact variables, secrets,
state migration and environment protection requirements.

## Domain and app HTTPS

The `include-domain` option in `infra-ci-cd.yaml` is manually triggered on main in the protected bootstrap environment.
It registers `abu-pse.link` only with apply checked, adopts the registration-created
zone and provisions an ACM certificate for `tasky.abu-pse.link`. Registration contacts
come from `DOMAIN_CONTACT_JSON`; the app hostname comes from app-deployment secret
`APP_DOMAIN`. The opt-in app deployment job verifies the signed release, deploys Helm
on a runner with private EKS connectivity, then applies the ALB DNS alias stack.
See [complete setup](../../infra/terraform/domain/registration/README.md).
