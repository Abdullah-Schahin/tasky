"""Write non-secret CI Terraform/backend inputs from GitHub configuration."""
import json
import os
from pathlib import Path
import re

e = os.environ
values = json.loads(e['TFVARS_JSON'])
assert values['account_id'] == e['AWS_ACCOUNT_ID'], 'Unexpected target account'
assert values['region'] == e['AWS_REGION'], 'Unexpected target region'
assert re.fullmatch(r'[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]', e['TF_STATE_BUCKET'])
assert e['TF_STATE_KEY'] and not e['TF_STATE_KEY'].startswith('/')
# Do not use the deliberately public backup bucket for state or plans.
assert '-backup-' not in e['TF_STATE_BUCKET'], 'State must not use the exercise backup bucket'
root = Path('infra/terraform')
(root / 'ci.auto.tfvars.json').write_text(json.dumps(values))
backend = {'bucket': e['TF_STATE_BUCKET'], 'key': e['TF_STATE_KEY'],
           'region': e['AWS_REGION'], 'encrypt': True, 'use_lockfile': True,
           'allowed_account_ids': [e['AWS_ACCOUNT_ID']]}
Path(e['RUNNER_TEMP'], 'backend.hcl').write_text('\n'.join(f'{k} = {json.dumps(v)}' for k, v in backend.items()) + '\n')
