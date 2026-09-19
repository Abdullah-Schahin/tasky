#!/usr/bin/env python3
"""Read-only sandbox inventory. Does not change AWS resources or fetch secret values."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--profile', default='wiz')
parser.add_argument('--region', default='us-east-1')
parser.add_argument('--account-id', required=True)
args = parser.parse_args()
checks = {
    'eks_clusters': ['eks', 'list-clusters'],
    'ec2_instances': ['ec2', 'describe-instances', '--query', 'Reservations[].Instances[].{ID:InstanceId,State:State.Name,Name:Tags[?Key==`Name`].Value|[0]}'],
    'vpcs': ['ec2', 'describe-vpcs', '--query', 'Vpcs[].{ID:VpcId,CIDR:CidrBlock,Default:IsDefault}'],
    'cloudtrail': ['cloudtrail', 'describe-trails', '--query', 'trailList[].{Name:Name,ARN:TrailARN,HomeRegion:HomeRegion}'],
    'config_recorders': ['configservice', 'describe-configuration-recorders'],
    'config_channels': ['configservice', 'describe-delivery-channels'],
    'securityhub': ['securityhub', 'describe-hub'],
    'guardduty': ['guardduty', 'list-detectors'],
    's3_account_block': ['s3control', 'get-public-access-block', '--account-id', args.account_id],
    'iam_roles': ['iam', 'list-roles', '--query', 'Roles[].{Name:RoleName,ARN:Arn}'],
    'old_ubuntu_amis': ['ec2', 'describe-images', '--owners', '099720109477', '--filters',
        'Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-2024*',
        'Name=state,Values=available', '--query', 'sort_by(Images,&CreationDate)[-3:].{ID:ImageId,Name:Name,Created:CreationDate}'],
}
def query(item):
    name, command = item
    run = subprocess.run(['aws', *command, '--profile', args.profile, '--region', args.region,
                          '--output', 'json', '--cli-connect-timeout', '10', '--cli-read-timeout', '15'],
                         capture_output=True, text=True, timeout=75)
    try:
        result = json.loads(run.stdout) if run.returncode == 0 else run.stderr.strip()
    except ValueError:
        result = run.stdout.strip()
    return name, {'ok': run.returncode == 0, 'result': result}
with ThreadPoolExecutor(max_workers=5) as pool:
    print(json.dumps(dict(pool.map(query, checks.items())), indent=2))
