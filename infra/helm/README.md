# Tasky Kubernetes security exercise

These manifests implement the requirements supplied in the conversation. The referenced
PDF is not in this repository and has not been independently checked.
This is an intentionally vulnerable exercise stack: Tasky's dedicated service account
has cluster-admin. Use an isolated exercise cluster, not a shared production cluster.

Traffic flows from an internet-facing ALB in public subnets to Tasky pod IPs on
private-subnet EKS nodes. Tasky reaches an external MongoDB endpoint over the VPC's
permitted network path. No MongoDB StatefulSet is included.

## Objects and deliberate findings

| Object/control | Configuration | Exercise impact |
| --- | --- | --- |
| Namespace | `tasky`, PSA `enforce: privileged` | No restrictive Pod Security Admission enforcement; this does not itself make pods privileged |
| ServiceAccount | Dedicated `tasky`, token automounted | Compromised app can access Kubernetes API credentials |
| ClusterRoleBinding | `tasky-exercise-cluster-admin` grants `cluster-admin` | Those credentials allow cluster-wide administrative actions |
| NetworkPolicy | Intentionally absent | No segmentation provided by this stack; other cluster policies and AWS security groups may still restrict traffic |
| Seccomp/AppArmor | No explicit workload profile | Missing explicit hardening; runtime defaults may still apply, so do not claim protection is definitely disabled |
| Deployment | Two replicas, UID/GID 10001, dropped capabilities, no privilege escalation, probes and resource limits | Retains container hardening while RBAC remains deliberately excessive |
| Secret | Explicit `secretKeyRef` for `MONGODB_URI` and `SECRET_KEY` | Keeps values outside the Deployment; a Kubernetes Secret is not automatically proof of encrypted storage |
| Service/Ingress | ClusterIP and ALB IP targets, HTTPS with HTTP redirect | Public application entry point without public worker nodes |

`secret.yaml` is a reference template and is deliberately outside the Helm chart.
Real secrets are bootstrapped separately so deployments cannot overwrite credentials
with placeholders. There is no ConfigMap, HPA or PDB because this app does not need
those objects for the exercise.

## AWS and cluster prerequisites

1. EKS with AWS VPC CNI and a node group in private subnets. Nodes must have no public
   IPs and their subnet routes must not go directly to an internet gateway. Supply
   egress for GHCR image pulls, DNS, Kubernetes API access, and MongoDB as appropriate.
2. Label that verified private node group `exercise.tasky.io/network=private` in its
   node-group configuration. The Deployment requires this label; without it, pods
   remain Pending. The label alone does not make a subnet private.
3. AWS Load Balancer Controller installed with its IAM permissions and the `alb`
   IngressClass. This stack targets the controller, not EKS Auto Mode.
4. Two public ALB subnet IDs in different AZs, with internet gateway routes and
   sufficient IP space. Public and private subnet placement is infrastructure work,
   not something these app manifests create.
5. An issued ACM certificate in the ALB's region for your application hostname.
   Point that hostname at the provisioned ALB using Route 53 alias or DNS CNAME.
6. Permit ALB-to-pod TCP 8080 and pod-to-MongoDB traffic in the relevant AWS security
   groups/routes. Restrict MongoDB's inbound rule to the intended workload source.
7. If GHCR is private, create a registry pull Secret in `tasky` and pass its name to
   Helm. CI's Docker login does not give Kubernetes permission to pull.

The deployment identity needs permission to create the namespace and ClusterRoleBinding,
including granting the referenced cluster-admin role. Keep that provisioning identity
separate from the intentionally overprivileged application identity.

## Bootstrap credentials

First apply the namespace:

```sh
kubectl create namespace tasky --dry-run=client -o yaml | kubectl apply -f -
```

Create an ignored local file `.env.k8s` with restrictive permissions (`chmod 600`)
containing real values, without shell quotes:

```text
MONGODB_URI=REPLACE_WITH_YOUR_MONGODB_CONNECTION_STRING
SECRET_KEY=REPLACE_WITH_A_LONG_RANDOM_SECRET
```

Replace the placeholder locally with your authenticated MongoDB connection string.
Percent-encode special characters in credentials and set the authentication database
for your MongoDB user. Use the MongoDB provider's TLS/SRV connection options when applicable. The application
selects **`go-mongodb` in code**, regardless of a different database name in the URI.

```sh
kubectl create secret generic tasky-secrets -n tasky \
  --from-env-file=.env.k8s --dry-run=client -o yaml | kubectl apply -f -
```

Secret-backed environment variables are read at pod creation. After rotating them,
restart the Deployment. Do not paste secret values or token contents into demo evidence.

## Render and deploy

The chart is in `infra/helm/tasky`. Install Helm 3.17+ or Helm 4. Fill in
`infra/helm/values-aws.yaml` with your hostname, ACM certificate ARN, and at least
two distinct public subnet IDs. These values are not credentials; keep MongoDB
and JWT secrets in the separately bootstrapped Kubernetes Secret.

Set `IMAGE` to the exact image digest after verifying the release signature and
attestations. Helm checks digest syntax, not signatures.

```sh
helm template tasky infra/helm/tasky --namespace tasky \
  -f infra/helm/values-aws.yaml --set-string "image.reference=$IMAGE" \
  > /tmp/tasky-manifests.yaml
kubectl --context YOUR_EKS_CONTEXT apply --dry-run=server -f /tmp/tasky-manifests.yaml

helm upgrade --install tasky infra/helm/tasky \
  --kube-context YOUR_EKS_CONTEXT --namespace tasky --create-namespace \
  -f infra/helm/values-aws.yaml --set-string "image.reference=$IMAGE" \
  --wait --timeout 5m
```

For the first migration of existing resources, including a bootstrapped namespace,
add `--take-ownership` to the upgrade command. Omit it on later upgrades. Use release
name `tasky`; the chart preserves stable resource names and supports one release
per namespace. For private GHCR, set `imagePullSecrets` in the AWS values file.

`values.schema.json` validates merged values during Helm rendering, linting, and
deployment: AWS images must use SHA256 digests, hostnames cannot use `.invalid`,
certificate ARNs must be well formed, and subnet IDs must be valid and distinct.
It does not verify that AWS resources exist, occupy different AZs, or are reachable.
Local nginx values allow development image tags and do not require AWS settings.
The placeholders deliberately fail validation until replaced.

```sh
helm lint infra/helm/tasky -f infra/local/values.yaml
```

The opt-in AWS app deployment job reads secret `APP_DOMAIN`, variable
`ACM_CERTIFICATE_ARN`, and JSON-array variable `PUBLIC_SUBNET_IDS`, then generates
Helm values for the signed image digest. Configure the private EKS runner and
follow the [domain setup](../freedns.md) before enabling it.
Namespace/Secret bootstrapping and initial Helm adoption are manual prerequisites.

## Demo and evidence

```sh
kubectl get deployments,pods,services,ingresses -n tasky -o wide
kubectl describe deployment tasky -n tasky
kubectl get nodes -l exercise.tasky.io/network=private -o wide
kubectl get nodes -l exercise.tasky.io/network=private \
  -o custom-columns=NAME:.metadata.name,PROVIDER:.spec.providerID

# Use an administrator with impersonation permission; does not extract a token.
kubectl auth can-i '*' '*' --all-namespaces \
  --as=system:serviceaccount:tasky:tasky
kubectl get clusterrolebinding tasky-exercise-cluster-admin -o yaml
kubectl exec -n tasky deployment/tasky -- id
kubectl exec -n tasky deployment/tasky -- sh -c \
  'test -s /var/run/secrets/kubernetes.io/serviceaccount/token && echo "API token is mounted"'
kubectl get networkpolicy -n tasky
kubectl get namespace tasky --show-labels
```

Use the node provider IDs to inspect EC2 instances, subnet IDs, public IP assignments,
and subnet route tables in AWS. Record that evidence alongside the ALB's public subnet
IDs. A pod IP or node label by itself is not proof of private-subnet placement.

For persistence proof:

1. Open the HTTPS application, sign up/sign in, and create a todo with a unique name,
   such as `wiz-demo-2026-09-18-001`.
2. From an authorized database client on the MongoDB network, authenticate with a
   password prompt (avoid putting credentials in a command line), then run:

   ```javascript
   db.getSiblingDB("go-mongodb").todos.find(
     { name: "wiz-demo-2026-09-18-001" },
     { _id: 1, name: 1, status: 1, user_id: 1 }
   )
   ```

3. Capture the matching document and UI result. Optionally restart Tasky pods and
   query the same record again to demonstrate persistence outside the pod.

The `/` readiness/liveness probes only test HTTP serving, **not MongoDB connectivity**.
The current app prints its MongoDB URI in `database/database.go`; redact that logging
before capturing logs with real credentials. Its "Connected" log message is not
proof of a successful database write. No changes to application code are made here.

## Cleanup

```sh
# Delete Ingress first; wait for the controller to remove the ALB before removing it.
kubectl delete ingress tasky -n tasky
helm uninstall tasky -n tasky
# Namespace and external Secrets are retained; delete only when no longer needed.
# kubectl delete namespace tasky
```

Helm removes the cluster-scoped ClusterRoleBinding on uninstall.
Confirm ALB and target group cleanup in AWS; external MongoDB data remains intact.

References: [AWS ALB annotations](https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/guide/ingress/annotations/),
[AWS private node subnet guidance](https://docs.aws.amazon.com/eks/latest/best-practices/subnets.html),
[Kubernetes Pod Security Admission](https://kubernetes.io/docs/concepts/security/pod-security-admission/).

## FreeDNS and certificate

The platform requests an ACM certificate for `tasky-abu-pse.apps.dj`. Add its validation
CNAME in FreeDNS and wait for issuance. The app workflow supplies `APP_DOMAIN` and
`ACM_CERTIFICATE_ARN` to Helm, then reports the ALB hostname for your FreeDNS app CNAME.
See [FreeDNS setup](../freedns.md). CI does not modify FreeDNS records.
