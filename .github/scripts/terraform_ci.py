"""Shared Terraform CI input, backend and state-storage configuration."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path('infra/terraform')
ROOTS = {'bootstrap': ROOT/'bootstrap', 'platform': ROOT/'platform'}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def account_region(env):
    account, region = env.get('AWS_ACCOUNT_ID', ''), env.get('AWS_REGION', '')
    require(re.fullmatch(r'[0-9]{12}', account), 'AWS_ACCOUNT_ID must contain 12 digits')
    require(re.fullmatch(r'(us|eu|ap|sa|ca|me|af|il|mx)-[a-z]+-[0-9]+', region), 'Set a commercial AWS_REGION')
    return account, region


def private_json(path, values):
    path.write_text(json.dumps(values) + '\n')
    path.chmod(0o600)


def write_backend(path, bucket, key, region, account):
    require(re.fullmatch(r'[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]', bucket) and '-backup-' not in bucket,
            'Supply the private bootstrap state bucket')
    require(key and not key.startswith('/') and '\n' not in key, 'Invalid state key')
    config = dict(bucket=bucket, key=key, region=region, encrypt=True,
                  use_lockfile=True, allowed_account_ids=[account])
    path.write_text('\n'.join(f'{k} = {json.dumps(v)}' for k, v in config.items()) + '\n')


def verify_state_bucket(env):
    account, _ = account_region(env)
    bucket = env['TF_STATE_BUCKET']
    require('-backup-' not in bucket, 'State must not use the exercise backup bucket')
    def read(operation):
        return json.loads(subprocess.check_output(['aws', 's3api', operation, '--bucket', bucket,
                          '--expected-bucket-owner', account, '--output', 'json'], text=True))
    blocks = read('get-public-access-block')['PublicAccessBlockConfiguration']
    require(all(blocks.get(k) is True for k in ['BlockPublicAcls', 'IgnorePublicAcls', 'BlockPublicPolicy', 'RestrictPublicBuckets']),
            'State bucket must block all public access')
    require(read('get-bucket-versioning').get('Status') == 'Enabled', 'State bucket must be versioned')
    rules = read('get-bucket-encryption')['ServerSideEncryptionConfiguration']['Rules']
    require(any(r['ApplyServerSideEncryptionByDefault']['SSEAlgorithm'] in ['AES256', 'aws:kms'] for r in rules),
            'State bucket must have encryption enabled')


def prepare(mode, env):
    account, region = account_region(env)
    temp = Path(env['RUNNER_TEMP'])
    if mode == 'bootstrap':
        prefix = env.get('BOOTSTRAP_PREFIX') or 'tasky-wiz'
        repository = env.get('GITHUB_REPOSITORY', '')
        owner_id = env.get('GITHUB_REPOSITORY_OWNER_ID', '')
        repository_id = env.get('GITHUB_REPOSITORY_ID', '')
        require(owner_id.isdigit() and repository_id.isdigit(), 'GitHub Actions repository owner/repository IDs are required for immutable OIDC trust.')
        key = env.get('TF_STATE_KEY') or 'infra/terraform.tfstate'
        oidc = env.get('AWS_GITHUB_OIDC_PROVIDER_ARN') or None
        require(re.fullmatch(r'[a-z][a-z0-9-]{2,19}', prefix), 'Invalid BOOTSTRAP_PREFIX')
        require(re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository), 'Invalid GitHub repository')
        require(re.fullmatch(r'infra/[A-Za-z0-9/_-]+\.tfstate', key), 'TF_STATE_KEY must be under infra/ and end in .tfstate')
        require(oidc is None or oidc == f'arn:aws:iam::{account}:oidc-provider/token.actions.githubusercontent.com', 'OIDC provider must belong to this account')
        private_json(ROOTS[mode]/'ci.auto.tfvars.json', dict(account_id=account, region=region,
            prefix=prefix, github_repository=repository, state_key=key,
            github_repository_owner_id=owner_id, github_repository_id=repository_id,
            AWS_GITHUB_OIDC_PROVIDER_ARN=oidc))
        bucket = f'{prefix}-tfstate-{account}-{region}'
        write_backend(temp/'bootstrap-backend.hcl', bucket, 'bootstrap/terraform.tfstate', region, account)
        with open(env['GITHUB_ENV'], 'a') as output:
            output.write(f'BOOTSTRAP_STATE_BUCKET={bucket}\n')
    elif mode == 'platform':
        raw_values = env.get('TFVARS_JSON', '').strip()
        require(raw_values, 'Set the repository Actions variable TFVARS_JSON to the platform inputs as JSON; it is currently missing or empty.')
        values = json.loads(raw_values)
        require(values['account_id'] == account and values['region'] == region, 'Unexpected target account/region')
        prefix = values.get('prefix', 'tasky-wiz')
        require(values.get('workload_permissions_boundary_arn') == f'arn:aws:iam::{account}:policy/{prefix}-workload-boundary', 'Use the bootstrap workload boundary')
        require(values.get('app_deploy_role_arn') == f'arn:aws:iam::{account}:role/{prefix}-ci-app', 'Use the bootstrap app role')
        private_json(ROOTS[mode]/'ci.auto.tfvars.json', values)
        write_backend(temp/'backend.hcl', env['TF_STATE_BUCKET'], env['TF_STATE_KEY'], region, account)
    else:
        raise ValueError('Use bootstrap, platform or check-state')


if __name__ == '__main__':
    os.umask(0o077)
    mode = sys.argv[1]
    if mode == 'check-state':
        verify_state_bucket(os.environ)
    else:
        prepare(mode, os.environ)
