# Automated private cluster setup

Infra CI/CD now runs: validate/scans → plan → protected Apply → private cluster setup.
The last job uses the existing registered `tasky-eks` runner and the protected
`infra-deplyoment` environment. No public EKS endpoint is needed. Plan-only runs do
not touch Kubernetes. The same environment may reuse approval within a run: approve
infrastructure Apply knowing it also authorizes the following cluster setup stage.

## First run

1. Push the changes. Run Bootstrap Infra with apply to create `tasky-wiz-ci-cluster`
   and grant infrastructure roles management/read access to the scoped SSM document.
2. Run Infra CI/CD with apply and approve its plan. Terraform grants the cluster role
   EKS cluster-admin access and adds SSM permissions to MongoDB's instance role.
3. The private-runner job installs official AWS Load Balancer Controller chart 1.14.1
   (controller 2.14.1, matching our vendored IAM policy), then provisions prerequisites:
   - `tasky-cluster-bootstrap` Helm release in `kube-system`, owning namespace `tasky`
     and the deliberate cluster-admin binding for service account `tasky`.
   - `tasky-secrets`, using the app password from Secrets Manager and a generated
     application signing key. Existing signing keys are preserved on reruns.
   - `tasky-mongo-ca`, obtained through a fixed SSM document that reads only the public
     CA after the MongoDB service and first-backup completion marker are verified.
4. After success, run App CI/CD and approve deployment. The app Helm chart continues
   using `clusterResources.create=false` and Secret-backed `MONGODB_URI` environment
   injection, satisfying the exercise's Kubernetes environment-variable requirement.

No passwords are passed as CLI arguments, written to files, printed, or stored as Helm
values. Secret manifests go through stdin. Existing Secret ownership conflicts fail
rather than force-overwriting another manager. The custom SSM document has no input
parameters and does not allow arbitrary commands. The setup role can read only the
project MongoDB Secret ARN pattern; externally supplied secrets/custom KMS keys need
explicit corresponding IAM grants before use.

MongoDB must be SSM-managed (the Canonical AMI includes the agent), have finished
cloud-init, and have a successful first backup. The job fails if these are missing;
it does not create an unauthenticated database or bypass TLS. Inspect cloud-init/SSM
on MongoDB if setup fails. Replacing MongoDB rotates the CA and loses root-disk data;
rerun infra setup and redeploy/restart the app after such a replacement. Do not rotate
Secrets Manager passwords independently of database users.

The runner must already be registered for this job to start. Runner registration still
requires the one-time short-lived token: Terraform cannot create a GitHub runner
registration without GitHub administrative credentials. If Terraform replaces the
runner, register the replacement before this queued job can run.

The setup role is privileged and isolated from normal app deploy permissions. It has
no Terraform state access. Only trusted main-branch workflows should use the private
runner. Protect `infra-deplyoment` with reviewers and main-only branch restrictions.
For an existing manually managed namespace/binding, review and migrate Helm ownership
before using this release; the workflow does not silently take ownership.

The bootstrap chart keeps namespace/RBAC on uninstall to avoid accidental data deletion.
Controller upgrades need chart/CRD and IAM-policy review together; this implementation
pins the initial version rather than automatically upgrading it.

Readiness is not inferred from EC2/SSM availability. The CA document waits up to ten
minutes for cloud-init, then checks the successful-bootstrap marker, active mongod
and certificate chain. Cluster setup polls long enough for that wait. On failure it
reports a safe reason, instance ID and SSM command ID without publishing raw output.
