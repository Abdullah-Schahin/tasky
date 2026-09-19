#!/usr/bin/env python3
"""Install cluster prerequisites; never print credentials or persist them in Helm."""
import base64
import json
import os
from pathlib import Path
import secrets
import subprocess
import time
from urllib.parse import quote


def run(*args, payload=None):
    result = subprocess.run(args, input=payload, text=True, capture_output=True)
    if result.returncode:
        # kubectl errors may include submitted Secret values; omit captured output.
        raise RuntimeError(f'{args[0]} {args[1]} failed (exit {result.returncode}); check service status')
    return result.stdout


def main():
    c = json.loads(os.environ['CLUSTER_SETUP'])
    run('aws', 'eks', 'update-kubeconfig', '--name', c['cluster'], '--region', c['region'])
    run('helm', 'upgrade', '--install', 'tasky-cluster-bootstrap', 'infra/helm/cluster-bootstrap',
        '-n', 'kube-system', '--wait', '--timeout', '5m')
    run('helm', 'repo', 'add', 'eks', 'https://aws.github.io/eks-charts', '--force-update')
    run('helm', 'repo', 'update', 'eks')
    values = {'clusterName': c['cluster'], 'region': c['region'], 'vpcId': c['vpc'],
        'serviceAccount': {'create': True, 'name': 'aws-load-balancer-controller',
          'annotations': {'eks.amazonaws.com/role-arn': c['controller_role']}},
        'defaultTags': {'created by': 'Abu', 'for': 'Wiz PSE'}}
    run('helm', 'upgrade', '--install', 'aws-load-balancer-controller', 'eks/aws-load-balancer-controller',
        '--version', '1.14.1', '-n', 'kube-system', '-f', '-', '--wait', '--timeout', '10m', payload=json.dumps(values))
    # SSM registration/IAM propagation may lag behind Terraform completion.
    command = None
    for _ in range(60):
        try:
            command = json.loads(run('aws', 'ssm', 'send-command', '--instance-ids', c['mongo_instance'],
                '--document-name', c['ca_document'], '--output', 'json'))['Command']['CommandId']
            break
        except RuntimeError:
            time.sleep(10)
    if not command:
        raise RuntimeError('MongoDB is not available through SSM; inspect its agent and instance role')
    ca = None
    # The document may wait ten minutes for cloud-init; allow execution and delivery overhead.
    deadline = time.monotonic() + 720
    while time.monotonic() < deadline:
        try:
            result = json.loads(run('aws', 'ssm', 'get-command-invocation', '--command-id', command,
                '--instance-id', c['mongo_instance'], '--output', 'json'))
        except RuntimeError:
            time.sleep(5)
            continue
        if result['Status'] == 'Success':
            ca = result['StandardOutputContent'].strip()
            break
        if result['Status'] in ('Failed', 'Cancelled', 'TimedOut'):
            codes = {
                'TASKY_BOOTSTRAP_TIMEOUT': 'cloud-init did not finish within 10 minutes',
                'TASKY_BOOTSTRAP_INCOMPLETE': 'cloud-init finished without successful database setup and first backup',
                'TASKY_MONGODB_INACTIVE': 'mongod is not active',
                'TASKY_CA_INVALID': 'MongoDB certificate does not validate against its CA',
            }
            # Only emit known diagnostics, never arbitrary SSM output or secrets.
            detail = next((v for k, v in codes.items() if k in result.get('StandardErrorContent', '')),
                          'readiness document failed; inspect its SSM invocation')
            raise RuntimeError(f"MongoDB {c['mongo_instance']}: {detail}; SSM command {command}")
        time.sleep(5)
    if not ca or not ca.startswith('-----BEGIN CERTIFICATE-----'):
        raise RuntimeError(f"MongoDB {c['mongo_instance']}: CA not returned within readiness deadline; SSM command {command}")
    credentials = json.loads(json.loads(run('aws', 'secretsmanager', 'get-secret-value',
        '--secret-id', c['mongo_secret'], '--output', 'json'))['SecretString'])
    password = credentials['app_password']
    if not isinstance(password, str) or not password:
        raise RuntimeError('Missing MongoDB app password')
    existing = run('kubectl', '-n', 'tasky', 'get', 'secret', 'tasky-secrets', '--ignore-not-found', '-o', 'json')
    key = json.loads(existing).get('data', {}).get('SECRET_KEY') if existing.strip() else None
    key = base64.b64decode(key).decode() if key else secrets.token_urlsafe(48)
    uri = f"mongodb://tasky_app:{quote(password, safe='')}@{c['mongo_ip']}:27017/go-mongodb?authSource=admin&tls=true&tlsCAFile=/etc/tasky-mongo-tls/ca.crt"
    for name, data in [('tasky-secrets', {'MONGODB_URI': uri, 'SECRET_KEY': key}), ('tasky-mongo-ca', {'ca.crt': ca})]:
        obj = {'apiVersion': 'v1', 'kind': 'Secret', 'metadata': {'name': name, 'namespace': 'tasky'},
               'type': 'Opaque', 'data': {k: base64.b64encode(v.encode()).decode() for k, v in data.items()}}
        run('kubectl', 'apply', '--server-side', '--field-manager=tasky-infra', '-f', '-', payload=json.dumps(obj))
    with Path(os.environ['GITHUB_STEP_SUMMARY']).open('a') as f:
        f.write('## Cluster prerequisites ready\n\nController and cluster bootstrap Helm releases installed; MongoDB connection and CA Secrets provisioned. App CI/CD can now deploy.\n')


if __name__ == '__main__':
    main()
