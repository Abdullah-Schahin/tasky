# Private app deployment runner

Terraform creates one Ubuntu 24.04 `t3.medium` in a private subnet, with an encrypted
30 GiB root disk, IMDSv2, no public IP, no SSH key and no inbound security-group rules.
It uses the existing NAT for HTTP package downloads and HTTPS GitHub/AWS traffic.
Only its security group is allowed to reach the EKS cluster security group on TCP 443.
The EKS API remains private. All taggable resources inherit the exercise tags.

The instance role has only AmazonSSMManagedInstanceCore, bounded by the workload
permissions boundary. It has no EKS deployment or Secrets Manager permissions.
The approved app job obtains its deployment credentials through GitHub OIDC.
Builds, tests, scans and publishing remain on GitHub-hosted runners.

## Deploy and register

1. Push these changes and run **Bootstrap Infra with apply** first. This allows the
   infrastructure role to manage the runner identity and attach the SSM policy.
2. Run **Infra CI/CD with apply**, review the plan, then approve. Inspect any unrelated
   replacements, particularly MongoDB, before approval. No new Terraform inputs are needed.
3. In EC2, select `tasky-wiz-runner` → Connect → Session Manager. Alternatively use the
   Terraform `runner_instance_id` output with `aws ssm start-session --target INSTANCE_ID`.
   Your operator identity needs SSM session permissions; the sandbox may restrict them.
4. In the session, wait for installation and check readiness:

   ```sh
   sudo cloud-init status --wait --long
   sudo test -f /var/lib/tasky-runner-ready && echo 'Runner tools ready'
   ```

   If bootstrap fails, inspect `/var/log/cloud-init-output.log` before retrying.
5. In GitHub → repository Settings → Actions → Runners → New self-hosted runner,
   select Linux/x64 and copy **only the registration token** from the configuration
   command. The binaries are already installed. Tokens expire after one hour.
6. In the SSM session run:

   ```sh
   sudo /usr/local/sbin/register-tasky-runner
   ```

   Paste the token at the hidden prompt. Do not put it in Terraform, shell history,
   GitHub variables or an SSM Run Command (whose parameters can be logged).
7. Confirm `tasky-eks-deploy` is Online/Idle in GitHub with labels `self-hosted`,
   `Linux`, `X64`, `tasky-eks`. Approve an App CI/CD deployment only after the cluster's
   controller, namespace/RBAC and MongoDB secrets are ready.

The bootstrap installs Git, Python, AWS CLI, Docker CLI, kubectl 1.35.0, Helm 3.19.0,
and GitHub runner 2.337.0. AWS CLI v2 uses the officially supported, auto-updating
`aws-cli` snap because this Ubuntu image has no `awscli` APT candidate. Downloaded kubectl/Helm archives use upstream checksum
verification; the initial runner archive has a pinned SHA256. Runner automatic
updates stay enabled. Ubuntu security updates remain enabled, unlike the deliberately
outdated MongoDB machine. Docker's daemon is disabled; deployment only uses its login
client. Cimon requires sudo, so the service uses Ubuntu's sudo-enabled user.

## Access and lifecycle

Require reviewers and main-only branches for `app-deployment`. Protect main and review
workflow changes. Labels select jobs, but **are not a security boundary**: repository
administrators/workflow authors can route other jobs to this persistent runner. Never
route PR code to it. For stronger server-enforced workflow restrictions, use an
organization runner group restricted to the deployment workflow if your GitHub plan
supports that feature. This repository runner relies on trusted workflow changes.

The registration survives reboot. A replacement instance must be registered again;
remove the stale offline runner in GitHub before reusing its name. Remove registration
when destroying the lab. The host is persistent: restrict it to approved deployments
and rebuild it if compromise is suspected. It is not a Kubernetes administrator host;
operator setup uses your local AWS identity through the [SSM kubectl tunnel](../../KUBECTL-DEMO.md).

The AMI selects the latest official Canonical Ubuntu 24.04 image at plan time. An AMI
or user-data change can propose runner replacement, reviewed through normal Apply
approval. Runtime installation/SSM registration must be checked after apply; Terraform
validation does not prove cloud-init completed.
