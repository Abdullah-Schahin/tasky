# CI/CD and reusable security scans

`app-ci-cd.yaml` owns app build, Minikube tests, container build/evidence, and publishing.
`security-scans.yaml` is a reusable `workflow_call` workflow owning scanner execution,
report artifacts and per-scanner PR comments. Each enabled scanner runs in its own
parallel job with input validation, scanning, summary generation and immediate reporting.
There are no separate validation, reporting or final-gate runners. Shared validation
and comment steps use YAML anchors; commenting reads the local sanitized summary.

The app calls the workflow after tests and container creation, enabling TruffleHog,
Bearer, govulncheck and Trivy. Publishing/signing depends on the reusable workflow
succeeding. The image archive checksum is verified before scanning and publishing.
Infrastructure CI enables TruffleHog and Trivy configuration scanning.

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
      issues: write
    with:
      report-prefix: terraform
      trufflehog: true
      working-directory: infra/terraform/platform
```

This example enables secret scanning only. Enable `trivy-infra` to scan configuration.
Future scanners need one job and support in the shared report formatter; callers opt
in through workflow inputs.

| Input | Default | Purpose |
| --- | --- | --- |
| `report-prefix` | Required | Unique lowercase name per call in a run, e.g. `app-source`, `app-image`, `terraform`, `kubernetes` |
| `trufflehog`, `bearer`, `govulncheck`, `trivy`, `trivy-infra` | `false` | Select scanners; at least one must be enabled |
| `working-directory` | `.` | Bearer and govulncheck scan path; TruffleHog scans the Git commit range |
| `image-artifact-id` | Empty | Required by Trivy; artifact in this run containing `tasky-image.tar` |
| `image-sha256` | Empty | Required by Trivy; expected SHA256 of the archive |
| `trivy-severity` | `CRITICAL` | Blocking container vulnerability severities |
| `comment-on-pr` | `true` | Post per-scanner comments on same-repository PRs |

Scanner failures fail the reusable workflow and block dependent deployment/publishing
jobs. Disabled scanners skip; selecting none fails input validation. Bearer and Trivy
infrastructure findings retain their existing exercise advisory `exit-code: 0` policy.
TruffleHog, govulncheck and image Trivy retain their blocking behavior.

No secrets inheritance is needed. Scanner jobs request `pull-requests: write` and `issues: write` to post
their own results; image Trivy also needs `actions: read` to download the archive.
This combines scanning and reporting privileges on the same runner. Checkout does not
persist credentials, and the token is explicitly passed to the comment step only.

## Reports and fork PRs

Each scanner's comment step runs after summary generation, including scan failure; it
does not wait for the other scanners or pipeline stages. Reports include outcome,
rule/detector IDs, locations or modules, and a workflow link. Artifact names and comment
markers include `report-prefix` to avoid collisions between calls in the same run.
There is one comment per prefix/scanner/run, updated on reruns. Comment API failures
are advisory and do not mask a failed scan or block an otherwise successful scan.

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
require the enabled scanner checks shown by the first GitHub run. Remove obsolete
`Selected scanners passed` or reporter checks from required checks. Local validation does not post comments or trigger workflows.

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

## Main-branch security issues

On main-branch pushes or manual runs, each scanner checks for an open same-repository
PR associated with the scanned commit. If present, it comments there; otherwise it
creates an issue containing its sanitized results, including clean scans, assigned to
`github.actor` (the original run actor, also on reruns). Each prefix/scanner/run has
one issue, updated on reruns, without concurrent jobs overwriting each other's reports.
`comment-on-pr` controls PR-event comments; main-branch reporting always runs.
Enable repository Issues. If GitHub rejects assignment or publication, the reporting
step shows an error; scan summaries and artifacts remain available and scanner verdicts
remain unchanged. Fork PRs do not publish comments or issues.
