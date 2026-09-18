What I implemented in the CICD is:
- I made sure to balance security and dev exprince
- I made sure to run things in parallel where applies and fails fast to not wast dev time
- I chained enough Security tools to make sure the code is secure before it reaches runtime

## Release evidence and deployment

`app-ci-cd.yaml` builds once, scans the image archive, and generates an SPDX JSON
SBOM with Trivy. It records workflow-generated SLSA v1 provenance containing the
source commit, workflow run, BuildKit metadata and scanned archive checksum.
This is an attested build record, not a claim of independently certified SLSA level.
The publishing job verifies archive/evidence checksums and uses Cosign keyless
signing to attach the image signature, SBOM and provenance to the pushed digest.

`verify-release` requires all three signatures from this repository's
`.github/workflows/app-ci-cd.yaml` on `refs/heads/main`, issued by
`https://token.actions.githubusercontent.com`, for the current commit. It also
checks the signed provenance's source repository, commit, ref and builder.
A missing/invalid attestation or a mismatched identity fails the job.

EKS deployment is opt-in: set repository variable `ENABLE_EKS_DEPLOY=true` and
configure `AWS_DEPLOY_ROLE_ARN`, `AWS_REGION`, and `EKS_CLUSTER_NAME`. Configure
any desired approval rules on the `production` environment. The cluster needs
the `tasky` namespace, `tasky-secrets`, and GHCR pull credentials if the image is
private. Deployment depends on successful verification and uses the verified
image digest; the placeholder image tag is replaced locally before applying.

This gate protects this workflow's deployment path. It is not a cluster admission
policy: users with direct Kubernetes write access can bypass it. The separate
legacy `build-and-publish.yml` workflow does not produce these release attestations
and its images will not satisfy this gate.
