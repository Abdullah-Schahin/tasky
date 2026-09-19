#!/usr/bin/env python3
"""Open an SSM tunnel for local kubectl, keeping AWS credentials on this computer."""
import argparse
import json
import os
from pathlib import Path
import shlex
import shutil
import socket
import subprocess
import tempfile
from urllib.parse import urlparse


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--profile', default='wiz')
    parser.add_argument('--region', default='us-east-1')
    parser.add_argument('--cluster', default='tasky-wiz')
    parser.add_argument('--runner-name', default='tasky-wiz-runner')
    parser.add_argument('--port', type=int, default=8443)
    args = parser.parse_args()
    for tool in ('aws', 'kubectl', 'session-manager-plugin'):
        if not shutil.which(tool):
            parser.error(f'{tool} is required on this computer; see infra/KUBECTL-DEMO.md')
    if not 1024 <= args.port <= 65535:
        parser.error('port must be between 1024 and 65535')
    with socket.socket() as check:
        check.bind(('127.0.0.1', args.port))
    aws = ['aws', '--profile', args.profile, '--region', args.region]
    cluster = json.loads(subprocess.check_output(aws + ['eks', 'describe-cluster', '--name', args.cluster, '--output', 'json']))['cluster']
    host = urlparse(cluster['endpoint']).hostname
    instances = json.loads(subprocess.check_output(aws + ['ec2', 'describe-instances', '--filters',
        f'Name=tag:Name,Values={args.runner_name}', 'Name=instance-state-name,Values=running', '--output', 'json']))
    targets = [i['InstanceId'] for r in instances['Reservations'] for i in r['Instances']]
    if len(targets) != 1:
        raise RuntimeError(f'Expected one running {args.runner_name} instance, found {len(targets)}')
    # Separate kubeconfig: never overwrite the user's normal context or credentials.
    with tempfile.TemporaryDirectory(prefix='tasky-kubectl-') as directory:
        config = Path(directory) / 'config'
        subprocess.run(aws + ['eks', 'update-kubeconfig', '--name', args.cluster,
            '--alias', 'tasky-demo', '--kubeconfig', str(config)], check=True)
        config.chmod(0o600)
        subprocess.run(['kubectl', '--kubeconfig', str(config), 'config', 'set-cluster', cluster['arn'],
            f'--server=https://127.0.0.1:{args.port}', f'--tls-server-name={host}'], check=True)
        # Preserve the EKS CA and verify the original server hostname through the tunnel.
        print('\nOnce the session says the port is open, run in a SECOND terminal:', flush=True)
        print(f'export KUBECONFIG={shlex.quote(str(config))}', flush=True)
        print('kubectl --request-timeout=15s get nodes -o wide', flush=True)
        print('\nKeep this terminal open; Ctrl-C closes the tunnel and removes its kubeconfig.', flush=True)
        parameters = {'host': [host], 'portNumber': ['443'], 'localPortNumber': [str(args.port)]}
        subprocess.run(aws + ['ssm', 'start-session', '--target', targets[0],
            '--document-name', 'AWS-StartPortForwardingSessionToRemoteHost',
            '--parameters', json.dumps(parameters)], check=True)


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        print('\nTunnel closed. Run unset KUBECONFIG in the second terminal.')
    except (subprocess.CalledProcessError, RuntimeError, OSError) as error:
        raise SystemExit(f'Tunnel failed: {error}')
