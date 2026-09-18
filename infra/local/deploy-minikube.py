#!/usr/bin/env python3
"""Build and deploy Tasky plus MongoDB to an isolated Minikube profile."""
import argparse
import base64
import json
from pathlib import Path
import secrets
import shutil
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parents[2]


def run(command, **kwargs):
    return subprocess.run(command, check=True, text=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--profile', default='tasky-local')
    parser.add_argument('--driver', default='docker')
    parser.add_argument('--memory', default='4096', help='Minikube memory in MiB')
    parser.add_argument('--cpus', default='2')
    parser.add_argument('--adopt-existing', action='store_true', help='Adopt existing exercise resources into the Helm release')
    args = parser.parse_args()
    for tool in ('minikube', 'kubectl', 'helm'):
        if not shutil.which(tool):
            parser.error(f'{tool} must be installed')
    mini = ['minikube', '-p', args.profile]
    kube = ['kubectl', '--context', args.profile]
    print(f'Starting Minikube profile {args.profile}; retaining the exercise cluster-admin binding.', flush=True)
    run([*mini, 'start', '--driver', args.driver, '--memory', args.memory,
         '--cpus', args.cpus, '--keep-context'])
    run([*mini, 'addons', 'enable', 'default-storageclass'])
    run([*mini, 'addons', 'enable', 'storage-provisioner'])
    run([*mini, 'addons', 'enable', 'ingress'])
    run([*kube, '-n', 'ingress-nginx', 'rollout', 'status',
         'deployment/ingress-nginx-controller', '--timeout=300s'])
    image = 'tasky-local:dev-' + uuid.uuid4().hex[:12]
    run([*mini, 'image', 'build', '-t', image, str(ROOT)])
    existing_namespace = run([*kube, 'get', 'namespace', 'tasky', '--ignore-not-found',
                              '-o', 'name'], capture_output=True).stdout.strip()
    if not existing_namespace:
        # Secrets need a namespace before Helm installs the workloads.
        namespace = {'apiVersion': 'v1', 'kind': 'Namespace', 'metadata': {
            'name': 'tasky', 'labels': {'app.kubernetes.io/managed-by': 'Helm'},
            'annotations': {'meta.helm.sh/release-name': 'tasky',
                            'meta.helm.sh/release-namespace': 'tasky'}}}
        run([*kube, 'create', '-f', '-'], input=json.dumps(namespace))

    def get_secret(name):
        result = run([*kube, '-n', 'tasky', 'get', 'secret', name,
                      '--ignore-not-found', '-o', 'json'], capture_output=True)
        if not result.stdout.strip():
            return None
        return {key: base64.b64decode(value).decode() for key, value in json.loads(result.stdout)['data'].items()}

    def apply_secret(name, values):
        # Pass credentials over stdin, never in command arguments, logs or a disk file.
        document = {'apiVersion': 'v1', 'kind': 'Secret', 'type': 'Opaque',
                    'metadata': {'name': name, 'namespace': 'tasky'}, 'stringData': values}
        run([*kube, 'apply', '-f', '-'], input=json.dumps(document), capture_output=True)

    credentials = get_secret('tasky-local-mongo')
    if credentials is None:
        # Reinitializing credentials against an old database volume would break authentication.
        pvc = run([*kube, '-n', 'tasky', 'get', 'pvc', 'tasky-mongo-data',
                   '--ignore-not-found', '-o', 'name'], capture_output=True).stdout.strip()
        if pvc:
            raise RuntimeError('MongoDB PVC exists but its credential Secret is missing; restore that Secret before deploying.')
        credentials = {'username': 'tasky_local', 'password': secrets.token_hex(24)}
        apply_secret('tasky-local-mongo', credentials)
    app_secret = get_secret('tasky-secrets') or {}
    from urllib.parse import quote
    uri = ('mongodb://' + quote(credentials['username'], safe='') + ':' +
           quote(credentials['password'], safe='') + '@mongo.tasky.svc.cluster.local:27017/go-mongodb?authSource=admin')
    apply_secret('tasky-secrets', {'MONGODB_URI': uri,
                                 'SECRET_KEY': app_secret.get('SECRET_KEY') or secrets.token_hex(32)})
    command = ['helm', 'upgrade', '--install', 'tasky', str(ROOT / 'infra/helm/tasky'),
               '--kube-context', args.profile, '--namespace', 'tasky',
               '-f', str(ROOT / 'infra/local/values.yaml'), '--set-string', 'image.reference=' + image,
               '--wait', '--timeout', '5m']
    if args.adopt_existing:
        command.append('--take-ownership')
    run(command)
    run([*kube, '-n', 'tasky', 'rollout', 'status', 'deployment/tasky-mongo', '--timeout=300s'])
    # Verify DB authentication without exposing credentials in host process arguments.
    run([*kube, '-n', 'tasky', 'exec', 'deployment/tasky-mongo', '--', 'mongosh', '--quiet', '--eval',
         'const d = db.getSiblingDB("admin"); const a = d.auth(process.env.MONGO_INITDB_ROOT_USERNAME, process.env.MONGO_INITDB_ROOT_PASSWORD); if (!(a === 1 || a.ok === 1)) quit(1); if (d.runCommand({ping:1}).ok !== 1) quit(1);'])
    run([*kube, '-n', 'tasky', 'rollout', 'status', 'deployment/tasky', '--timeout=300s'])
    print(f'''\nTasky and MongoDB deployed to {args.profile}.
Access through the ingress (leave this running in another terminal):
  kubectl --context {args.profile} -n ingress-nginx port-forward service/ingress-nginx-controller 8080:80
Then open http://tasky.localhost:8080
Direct app fallback:
  kubectl --context {args.profile} -n tasky port-forward service/tasky 8080:80
Then open http://localhost:8080
''')


if __name__ == '__main__':
    try:
        main()
    except (subprocess.CalledProcessError, RuntimeError) as error:
        print(f'Deployment failed: {error}', file=sys.stderr)
        sys.exit(1)
