# Local Tasky environments

`compose.yaml` remains available for Docker Compose. For Kubernetes, run from the
repository root:

```sh
python3 infra/local/deploy-minikube.py
```

Prerequisites: Python 3, Helm 3.17+ (or Helm 4), Minikube, kubectl, and a running Docker daemon for the
default Docker driver. The first run downloads Kubernetes, controller, MongoDB,
and build images and Go modules. Allow approximately 4 GiB RAM and two CPUs.

The script:

1. Starts/reuses the dedicated `tasky-local` Minikube profile, retaining your active
   kubectl context. Every Kubernetes operation explicitly targets that profile.
2. Enables storage and the local ingress controller.
3. Builds the current working tree inside Minikube for the node architecture and
   gives each build a unique tag. It does not publish to ECR.
4. Creates local random MongoDB/JWT credentials as Kubernetes Secrets without
   writing them to the repository. Existing credentials are reused on reruns.
5. Installs/upgrades the `tasky` Helm release using `infra/local/values.yaml`, including a single MongoDB
   Deployment, ClusterIP Service and 1 GiB PVC. MongoDB is not exposed to the host.
6. Checks MongoDB authentication/ping and waits for the app rollout.

The local application uses MongoDB's local initialization administrator for
convenience; this is not a production database access pattern. Data survives app
redeployments. Do not delete the MongoDB Secret while retaining the PVC: the script
will refuse to generate mismatched replacement credentials for existing data.

The application retains the exercise's cluster-admin binding, mounted service
account token and missing segmentation/PSA restrictions. The local values remove the
AWS subnet selector and ALB annotations; this local setup does not demonstrate
private AWS subnets. Local images bypass release signature verification deliberately
for development, and use `imagePullPolicy: Never` to prevent registry substitution.

## Migrate the existing local installation

Install Helm if needed (`brew install helm` on macOS), then run once:

```sh
python3 infra/local/deploy-minikube.py --adopt-existing
```

This adopts the existing exercise resources into Helm without replacing the MongoDB
PVC or regenerating credentials. Use the flag only for this migration; subsequent
runs need no flag. The release and namespace are both `tasky`; the chart uses stable
resource names and supports one installation per namespace.

```sh
helm --kube-context tasky-local list -n tasky
helm --kube-context tasky-local history tasky -n tasky
```

Secrets remain externally managed and are not stored in Helm values. The namespace
and MongoDB PVC have `helm.sh/resource-policy: keep`; uninstalling the release retains
them and the Secrets. Reinstallation after uninstall requires `--adopt-existing`.
Deleting the namespace or Minikube profile still deletes the database data.

## Open the app

For ingress routing on macOS, Docker Desktop or Linux, keep this running:

```sh
kubectl --context tasky-local -n ingress-nginx \
  port-forward service/ingress-nginx-controller 8080:80
```

Open **http://tasky.localhost:8080**. If your resolver does not resolve `.localhost`,
use `curl --resolve tasky.localhost:8080:127.0.0.1 http://tasky.localhost:8080/`
or add the hostname to your hosts file. This local ingress is HTTP, without AWS/ACM.

For access that bypasses ingress:

```sh
kubectl --context tasky-local -n tasky port-forward service/tasky 8080:80
```

Then open http://localhost:8080. Port forwarding binds to localhost by default.

## Customization and checks

```sh
python3 infra/local/deploy-minikube.py --help
python3 infra/local/deploy-minikube.py --profile tasky-demo --memory 6144 --cpus 4
kubectl --context tasky-local -n tasky get pods,services,ingress,pvc
kubectl --context tasky-local auth can-i '*' '*' --all-namespaces \
  --as=system:serviceaccount:tasky:tasky
```

Rerun the deployment script after code changes; the unique image tag forces a rollout.
It overwrites the local app's MongoDB URI to point to the local MongoDB Service.
Use a dedicated profile instead of pointing it at a cluster containing other work.

To inspect saved todos after creating one through the app:

```sh
kubectl --context tasky-local -n tasky exec deployment/tasky-mongo -- \
  mongosh --quiet --eval '
    db.getSiblingDB("admin").auth(process.env.MONGO_INITDB_ROOT_USERNAME, process.env.MONGO_INITDB_ROOT_PASSWORD);
    printjson(db.getSiblingDB("go-mongodb").todos.find({}, {name:1,status:1}).toArray());
  '
```

Tasky's current startup logging includes its MongoDB URI. Avoid sharing unredacted
application logs even when using this local setup.

## Cleanup

Stop the environment while retaining its data:

```sh
minikube stop -p tasky-local
```

Delete the entire local environment, including MongoDB data:

```sh
minikube delete -p tasky-local
```

## MongoDB on recent Docker Desktop kernels

MongoDB 8 can refuse startup on Linux 6.19+ (including Docker Desktop's
`7.0.12-linuxkit`) because its TCMalloc per-CPU allocator is incompatible with
those kernels (MongoDB SERVER-121912). The local MongoDB manifest sets
`GLIBC_TUNABLES=glibc.pthread.rseq=1`, letting glibc register rseq first so TCMalloc
uses per-thread caches instead. This local compatibility workaround may reduce
allocator performance; revisit it when the MongoDB/kernel combination is fixed.
It does not delete or reinitialize the database volume.

Rerun the Helm deployment script to apply chart changes.

See [MongoDB's allocator documentation](https://www.mongodb.com/docs/manual/administration/tcmalloc-performance/)
and the [official image discussion](https://github.com/docker-library/mongo/discussions/748).
