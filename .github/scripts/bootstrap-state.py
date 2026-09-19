"""Seed the stack's private bucket before enabling its S3 backend.

Only the initial bucket configuration is performed through AWS CLI. Terraform then
imports that bucket and manages it alongside the rest of the bootstrap resources.
"""
import json
import os
from pathlib import Path
import subprocess
import sys


def aws(*args, missing=()):
    result = subprocess.run(['aws', *args, '--output', 'json'], text=True, capture_output=True)
    if result.returncode:
        if any(f'({code})' in result.stderr for code in missing):
            return None
        raise RuntimeError(result.stderr.strip())
    return json.loads(result.stdout) if result.stdout.strip() else {}


def seed(config):
    account, region, prefix = (config[key] for key in ['account_id', 'region', 'prefix'])
    bucket = f'{prefix}-tfstate-{account}-{region}'
    owner = ['--bucket', bucket, '--expected-bucket-owner', account]
    if aws('sts', 'get-caller-identity')['Account'] != account:
        raise ValueError('Bootstrap credentials belong to a different AWS account')
    found = aws('s3api', 'head-bucket', *owner, missing=('404', 'NoSuchBucket'))
    tags = {'created by': 'Abu', 'for': 'Wiz PSE', 'Project': prefix, 'BootstrapState': 'true'}
    if found is None:
        args = ['s3api', 'create-bucket', '--bucket', bucket, '--object-ownership', 'BucketOwnerEnforced']
        if region != 'us-east-1':
            args += ['--create-bucket-configuration', json.dumps({'LocationConstraint': region})]
        aws(*args)
        aws('s3api', 'put-bucket-tagging', *owner, '--tagging', json.dumps(
            {'TagSet': [{'Key': k, 'Value': v} for k, v in tags.items()]}))
    else:
        actual = aws('s3api', 'get-bucket-tagging', *owner)
        actual = {tag['Key']: tag['Value'] for tag in actual['TagSet']}
        if any(actual.get(k) != v for k, v in tags.items()):
            raise ValueError('Existing bucket lacks bootstrap ownership tags; review/import it manually')
    denied_roles = [f'arn:aws:iam::{account}:role/{prefix}-{role}' for role in
                    ['eks', 'nodes', 'mongodb', 'config', 'load-balancer-controller', 'ci-app']]
    state = aws('s3api', 'head-object', *owner, '--key', 'bootstrap/terraform.tfstate', missing=('404', 'NoSuchKey'))
    if state is None:
        # Never replace missing state with an empty state for already-created identities.
        for suffix in ['ci-plan', 'ci-apply', 'ci-app']:
            if aws('iam', 'get-role', '--role-name', f'{prefix}-{suffix}', missing=('NoSuchEntity',)) is not None:
                raise ValueError('Bootstrap roles exist but remote bootstrap state is missing. Migrate/restore state first.')
        aws('s3api', 'put-public-access-block', *owner, '--public-access-block-configuration', json.dumps({
            key: True for key in ['BlockPublicAcls', 'IgnorePublicAcls', 'BlockPublicPolicy', 'RestrictPublicBuckets']}))
        aws('s3api', 'put-bucket-ownership-controls', *owner, '--ownership-controls', json.dumps(
            {'Rules': [{'ObjectOwnership': 'BucketOwnerEnforced'}]}))
        aws('s3api', 'put-bucket-versioning', *owner, '--versioning-configuration', 'Status=Enabled')
        aws('s3api', 'put-bucket-encryption', *owner, '--server-side-encryption-configuration', json.dumps(
            {'Rules': [{'ApplyServerSideEncryptionByDefault': {'SSEAlgorithm': 'AES256'}}]}))
        resources = [f'arn:aws:s3:::{bucket}', f'arn:aws:s3:::{bucket}/*']
        policy = {'Version': '2012-10-17', 'Statement': [
            {'Sid': 'RequireTLS', 'Effect': 'Deny', 'Principal': '*', 'Action': 's3:*', 'Resource': resources,
             'Condition': {'Bool': {'aws:SecureTransport': 'false'}}},
            {'Sid': 'ExcludeExerciseWorkloads', 'Effect': 'Deny', 'Principal': '*', 'Action': 's3:*', 'Resource': resources,
             'Condition': {'ArnEquals': {'aws:PrincipalArn': denied_roles}}},
        ]}
        aws('s3api', 'put-bucket-policy', *owner, '--policy', json.dumps(policy))
    # Fail closed if storage protections have drifted. No state is written before these checks.
    blocks = aws('s3api', 'get-public-access-block', *owner)['PublicAccessBlockConfiguration']
    if not all(blocks.get(k) is True for k in ['BlockPublicAcls', 'IgnorePublicAcls', 'BlockPublicPolicy', 'RestrictPublicBuckets']):
        raise ValueError('Bootstrap state bucket must block all public access')
    if aws('s3api', 'get-bucket-versioning', *owner).get('Status') != 'Enabled':
        raise ValueError('Bootstrap state bucket must have versioning enabled')
    encryption = aws('s3api', 'get-bucket-encryption', *owner)['ServerSideEncryptionConfiguration']['Rules']
    if not any(rule['ApplyServerSideEncryptionByDefault']['SSEAlgorithm'] in ['AES256', 'aws:kms'] for rule in encryption):
        raise ValueError('Bootstrap state bucket must have encryption enabled')
    policy = json.loads(aws('s3api', 'get-bucket-policy', *owner)['Policy'])
    if not any(s.get('Effect') == 'Deny' and s.get('Principal') == '*' and s.get('Action') == 's3:*'
               and s.get('Condition') == {'Bool': {'aws:SecureTransport': 'false'}}
               and set(s.get('Resource', [])) == {f'arn:aws:s3:::{bucket}', f'arn:aws:s3:::{bucket}/*'}
               for s in policy['Statement']):
        raise ValueError('Bootstrap state bucket must enforce TLS')
    if not any(s.get('Effect') == 'Deny' and s.get('Principal') == '*' and s.get('Action') == 's3:*'
               and set(s.get('Resource', [])) == {f'arn:aws:s3:::{bucket}', f'arn:aws:s3:::{bucket}/*'}
               and set(s.get('Condition', {}).get('ArnEquals', {}).get('aws:PrincipalArn', [])) >= set(denied_roles)
               for s in policy['Statement']):
        raise ValueError('Bootstrap state bucket must deny exercise workload access')
    with open(os.environ['GITHUB_ENV'], 'a') as output:
        output.write(f'BOOTSTRAP_HAS_STATE={str(state is not None).lower()}\n')
    Path('infra/bootstrap/backend.ci.tf').write_text('terraform {\n  backend "s3" {}\n}\n')
    print('Private bootstrap backend is ready; state key: bootstrap/terraform.tfstate')


if __name__ == '__main__':
    try:
        seed(json.loads(Path('infra/bootstrap/ci.auto.tfvars.json').read_text()))
    except FileNotFoundError as error:
        print(f'Bootstrap input file is missing: {error.filename}. '
              'Run bootstrap-ci-inputs.py before bootstrap-state.py in the same job.', file=sys.stderr)
        sys.exit(1)
    except (ValueError, RuntimeError, KeyError) as error:
        print(f'Bootstrap state setup failed: {error}', file=sys.stderr)
        sys.exit(1)
