# kubectl demo through the private runner

Run kubectl on your Mac through an SSM remote-host port-forwarding session. The runner
forwards TCP to the private EKS API; AWS credentials stay on your Mac. It does not
need a GitHub runner registration to forward traffic, only successful SSM startup.
No public EKS endpoint, public runner address, inbound SSH or new IAM role is needed.

## Prerequisites

- Apply the private runner infrastructure and verify SSM shows it Online.
- Install AWS CLI, kubectl (matching EKS minor version), Python 3 and the
  [AWS Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)
  on your Mac. The plugin is separate from AWS CLI.
- Your local `wiz` profile must authenticate as the existing `eks_admin_principal_arn`
  (or another explicitly authorized EKS operator). Terraform already grants that
  identity EKS cluster-admin access. The runner instance role remains SSM-only.
- Your operator must be allowed `eks:DescribeCluster`, `ec2:DescribeInstances`,
  `ssm:StartSession` for the runner instance and AWS document
  `AWS-StartPortForwardingSessionToRemoteHost`, and session lifecycle permissions
  (`ssm:ResumeSession`, `ssm:TerminateSession`) for their own sessions. Existing sandbox
  IAM/SCP restrictions may require lab administrator assistance; no broad operator
  IAM grants are added by this change.

## Connect

From the repository root in terminal 1:

```sh
aws --profile wiz sts get-caller-identity
python3 infra/scripts/kubectl-tunnel.py
```

The script discovers the runner and EKS endpoint and prints an `export KUBECONFIG=...`
command. Keep it running. When SSM reports the local port is open, paste that export
into terminal 2, then:

```sh
kubectl config current-context
kubectl --request-timeout=15s get nodes -o wide
```

The generated kubeconfig uses localhost for transport but retains the EKS CA and
original TLS server name. Certificate verification stays enabled. Authentication
uses the local AWS profile; never copy AWS keys to the runner. The temporary kubeconfig
is separate from `~/.kube/config` and is removed when the tunnel exits.

## Demo sequence

```sh
# Show nodes and private workload placement.
kubectl get nodes -o wide
kubectl -n tasky get deployment,pods -o wide
kubectl -n tasky rollout status deployment/tasky --timeout=60s

# Trace public ALB ingress to the internal Service and its endpoints.
kubectl -n tasky get ingress,service
kubectl -n tasky get endpointslices
kubectl -n tasky describe ingress tasky

# Explain health checks, image digest, service account and troubleshooting.
kubectl -n tasky describe deployment tasky
kubectl -n tasky get events --sort-by=.metadata.creationTimestamp

# Demonstrate the intentionally excessive workload privileges.
kubectl get clusterrolebinding tasky-exercise-cluster-admin -o yaml
kubectl auth can-i '*' '*' --as=system:serviceaccount:tasky:tasky --all-namespaces
```

The impersonation check shows authorization, not exploitation. The operator needs
impersonation permission; an authorization error is not proof the workload is safe.
Do not display Secret manifests or environment values. The app's direct MongoDB URI
logging has been removed; deploy the rebuilt image before showing app logs, and
review any other logs privately before screen sharing. Create a unique todo in the
browser, refresh, then separately show its document in MongoDB to prove persistence.

Stop terminal 1 with Ctrl-C, then run `unset KUBECONFIG` in terminal 2.

Timeout: check SSM online status, runner-to-EKS TCP 443, DNS and local port availability.
Unauthorized/Forbidden: check the local AWS identity and EKS access entry, not the
runner's instance role. Missing plugin: install the Session Manager plugin locally.
Port conflict: use `--port 8444`. Non-default setup: use `--profile`, `--region`,
`--cluster`, and `--runner-name`.

Session start/stop is auditable in AWS; port-forwarded command content is not recorded
by Session Manager. Kubernetes API requests are covered by enabled EKS audit logs.
See [AWS remote-host forwarding](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-sessions-start.html#sessions-remote-port-forwarding).
