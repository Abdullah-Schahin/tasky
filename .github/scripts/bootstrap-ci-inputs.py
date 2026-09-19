"""Validate GitHub configuration and write non-secret bootstrap inputs."""
import json
import os
from pathlib import Path
import re


def configuration(env):
    account = env.get('AWS_ACCOUNT_ID', '')
    region = env.get('AWS_REGION', '')
    prefix = env.get('BOOTSTRAP_PREFIX') or 'tasky-wiz'
    repository = env.get('GITHUB_REPOSITORY', '')
    state_key = env.get('TF_STATE_KEY') or 'infra/terraform.tfstate'
    provider = env.get('GITHUB_OIDC_PROVIDER_ARN') or None
    checks = [
        (re.fullmatch(r'[0-9]{12}', account), 'AWS_ACCOUNT_ID must contain 12 digits'),
        (re.fullmatch(r'(us|eu|ap|sa|ca|me|af|il|mx)-[a-z]+-[0-9]+', region), 'Set a commercial AWS_REGION'),
        (re.fullmatch(r'[a-z][a-z0-9-]{2,19}', prefix), 'Invalid BOOTSTRAP_PREFIX'),
        (re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository), 'Invalid GitHub repository'),
        (re.fullmatch(r'infra/[A-Za-z0-9/_-]+\.tfstate', state_key), 'TF_STATE_KEY must be under infra/ and end in .tfstate'),
        (provider is None or provider == f'arn:aws:iam::{account}:oidc-provider/token.actions.githubusercontent.com', 'OIDC provider must belong to this account'),
    ]
    for valid, message in checks:
        if not valid:
            raise ValueError(message)
    return dict(account_id=account, region=region, prefix=prefix,
                github_repository=repository, state_key=state_key,
                github_oidc_provider_arn=provider)


def main():
    values = configuration(os.environ)
    Path('infra/bootstrap/ci.auto.tfvars.json').write_text(json.dumps(values) + '\n')
    bucket = f"{values['prefix']}-tfstate-{values['account_id']}-{values['region']}"
    backend = dict(bucket=bucket, key='bootstrap/terraform.tfstate', region=values['region'],
                   encrypt=True, use_lockfile=True, allowed_account_ids=[values['account_id']])
    Path(os.environ['RUNNER_TEMP'], 'bootstrap-backend.hcl').write_text(
        '\n'.join(f'{key} = {json.dumps(value)}' for key, value in backend.items()) + '\n')
    with open(os.environ['GITHUB_ENV'], 'a') as output:
        output.write(f'BOOTSTRAP_STATE_BUCKET={bucket}\n')


if __name__ == '__main__':
    main()
