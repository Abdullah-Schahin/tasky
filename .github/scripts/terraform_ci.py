"""Shared Terraform CI input, backend and state-storage configuration."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path('infra/terraform')
ROOTS = {'bootstrap': ROOT/'bootstrap', 'platform': ROOT/'platform',
         'domain-registration': ROOT/'domain/registration', 'domain-tls': ROOT/'domain/tls',
         'app-dns': ROOT/'app-dns'}


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
        key = env.get('TF_STATE_KEY') or 'infra/terraform.tfstate'
        oidc = env.get('GITHUB_OIDC_PROVIDER_ARN') or None
        zone = env.get('APP_HOSTED_ZONE_ID') or None
        require(re.fullmatch(r'[a-z][a-z0-9-]{2,19}', prefix), 'Invalid BOOTSTRAP_PREFIX')
        require(re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository), 'Invalid GitHub repository')
        require(re.fullmatch(r'infra/[A-Za-z0-9/_-]+\.tfstate', key), 'TF_STATE_KEY must be under infra/ and end in .tfstate')
        require(oidc is None or oidc == f'arn:aws:iam::{account}:oidc-provider/token.actions.githubusercontent.com', 'OIDC provider must belong to this account')
        require(zone is None or re.fullmatch(r'Z[A-Z0-9]+', zone), 'Invalid APP_HOSTED_ZONE_ID')
        private_json(ROOTS[mode]/'ci.auto.tfvars.json', dict(account_id=account, region=region,
            prefix=prefix, github_repository=repository, state_key=key,
            github_oidc_provider_arn=oidc, app_dns_zone_id=zone))
        bucket = f'{prefix}-tfstate-{account}-{region}'
        write_backend(temp/'bootstrap-backend.hcl', bucket, 'bootstrap/terraform.tfstate', region, account)
        with open(env['GITHUB_ENV'], 'a') as output:
            output.write(f'BOOTSTRAP_STATE_BUCKET={bucket}\n')
    elif mode == 'platform':
        values = json.loads(env['TFVARS_JSON'])
        require(values['account_id'] == account and values['region'] == region, 'Unexpected target account/region')
        prefix = values.get('prefix', 'tasky-wiz')
        require(values.get('workload_permissions_boundary_arn') == f'arn:aws:iam::{account}:policy/{prefix}-workload-boundary', 'Use the bootstrap workload boundary')
        require(values.get('app_deploy_role_arn') == f'arn:aws:iam::{account}:role/{prefix}-ci-app', 'Use the bootstrap app role')
        private_json(ROOTS[mode]/'ci.auto.tfvars.json', values)
        write_backend(temp/'backend.hcl', env['TF_STATE_BUCKET'], env['TF_STATE_KEY'], region, account)
    elif mode == 'domain':
        try:
            contact = json.loads(env['DOMAIN_CONTACT_JSON'])
            fields = ['first_name', 'last_name', 'email', 'phone_number', 'address_line_1', 'city', 'country_code', 'zip_code']
            require(isinstance(contact, dict) and all(isinstance(contact.get(k), str) and contact[k].strip() for k in fields), 'Invalid contact')
        except (ValueError, KeyError):
            raise ValueError('DOMAIN_CONTACT_JSON must contain all required contact fields') from None
        for value in contact.values():
            if isinstance(value, str) and value:
                print('::add-mask::' + value.replace('%', '%25').replace('\r', '%0D').replace('\n', '%0A'))
        private_json(ROOTS['domain-registration']/'ci.auto.tfvars.json', dict(account_id=account, region='us-east-1', contact=contact))
        private_json(ROOTS['domain-tls']/'ci.auto.tfvars.json', dict(account_id=account, region=region))
        for root in ['domain-registration', 'domain-tls']:
            write_backend(temp/f'{root}-backend.hcl', env['TF_STATE_BUCKET'], f'{root}/terraform.tfstate', region, account)
    else:
        raise ValueError('Use bootstrap, platform, domain or check-state')


if __name__ == '__main__':
    os.umask(0o077)
    mode = sys.argv[1]
    if mode == 'check-state':
        verify_state_bucket(os.environ)
    else:
        prepare(mode, os.environ)
