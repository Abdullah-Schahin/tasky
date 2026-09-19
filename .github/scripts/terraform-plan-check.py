#!/usr/bin/env python3
"""Check the exercise's critical invariants in terraform show -json output."""
import argparse
import json
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('plan_json')
parser.add_argument('--summary', help='Append resource actions to the GitHub job summary')
args = parser.parse_args()
plan = json.loads(Path(args.plan_json).read_text())
resources = {r['address']: r for r in plan['planned_values']['root_module']['resources']}
managed = {k: r for k, r in resources.items() if r['mode'] == 'managed'}

def values(address):
    return resources[address]['values']

for address, resource in managed.items():
    value = resource['values']
    if 'tags_all' in value:
        assert value['tags_all'].get('created by') == 'Abu', address
        assert value['tags_all'].get('for') == 'Wiz PSE', address

private = [r for r in managed.values() if r['type'] == 'aws_subnet' and r['name'] == 'private']
assert len(private) == 2
assert all(not r['values']['map_public_ip_on_launch'] for r in private)
ssh = values('aws_vpc_security_group_ingress_rule.ssh')
assert ssh['cidr_ipv4'] == '0.0.0.0/0' and ssh['from_port'] == ssh['to_port'] == 22
mongo = values('aws_vpc_security_group_ingress_rule.mongodb')
assert mongo['from_port'] == mongo['to_port'] == 27017
assert not mongo.get('cidr_ipv4') and not mongo.get('cidr_ipv6')
config = {r['address']: r for r in plan['configuration']['root_module']['resources']}
refs = config['aws_vpc_security_group_ingress_rule.mongodb']['expressions']['referenced_security_group_id']['references']
assert 'aws_security_group.nodes.id' in refs
backup = values('aws_s3_bucket_public_access_block.backup')
assert backup['block_public_acls'] and backup['ignore_public_acls']
assert not backup['block_public_policy'] and not backup['restrict_public_buckets']
audit = values('aws_s3_bucket_public_access_block.audit')
assert all(audit[k] for k in ('block_public_acls','ignore_public_acls','block_public_policy','restrict_public_buckets'))
assert 'aws_s3_bucket_versioning.backup' not in managed
assert not any(r['type'] == 'aws_flow_log' for r in managed.values())
cluster = values('aws_eks_cluster.main')
assert {'audit', 'api', 'authenticator'} <= set(cluster['enabled_cluster_log_types'])
assert cluster['vpc_config'][0]['endpoint_private_access']
assert values('aws_launch_template.nodes')['metadata_options'][0]['http_tokens'] == 'required'
assert values('aws_instance.mongodb')['metadata_options'][0]['http_tokens'] == 'required'
if 'aws_instance.runner' in managed:
    runner = values('aws_instance.runner')
    assert not runner['associate_public_ip_address'], 'Runner must have no public IP'
    assert not runner.get('key_name'), 'Runner must use SSM, not SSH'
    assert runner['metadata_options'][0]['http_tokens'] == 'required'
    assert runner['root_block_device'][0]['encrypted']
    runner_refs = config['aws_instance.runner']['expressions']['subnet_id']['references']
    assert 'aws_subnet.private' in runner_refs, 'Runner must use a private subnet'
for r in managed.values():
    if r['type'] == 'aws_secretsmanager_secret_version':
        # Refreshed SDK state can represent an unset optional string as "".
        # Neither representation contains credentials; reject any actual value.
        for field in ('secret_string', 'secret_binary', 'secret_string_wo'):
            assert r['values'].get(field) in (None, ''), f"{r['address']}: {field} contains persisted secret material"
        expressions = config[r['address'].split('[')[0]]['expressions']
        assert 'secret_string_wo' in expressions, f"{r['address']}: write-only credentials required"
        assert not {'secret_string', 'secret_binary'} & expressions.keys(), f"{r['address']}: persisted credential arguments forbidden"
        assert r['values']['secret_string_wo_version'] == 1, r['address']
# Environment approval authorizes destructive actions in the exact saved plan.
# Report addresses/actions only; plan values can contain sensitive information.
changes = [r for r in plan['resource_changes']
           if r.get('mode', 'managed') == 'managed' and r['change']['actions'] != ['no-op']]
changes.sort(key=lambda r: ('delete' not in r['change']['actions'], r['address']))
destructive = [r for r in changes if 'delete' in r['change']['actions']]
lines = ['## Terraform actions to review', '',
         f'**{len(destructive)} resource(s) will be deleted or replaced.**', '',
         'Apply approval authorizes all actions in the saved plan, including data loss from deletion or replacement.', '',
         '| Resource | Actions |', '| --- | --- |']
for r in changes:
    address = r['address'].replace('|', '&#124;').replace('`', '&#96;').replace('\n', ' ')
    lines.append(f"| `{address}` | {' → '.join(r['change']['actions'])} |")
if not changes:
    lines.append('| None | No changes |')
if any(r['address'] == 'aws_instance.mongodb' for r in destructive):
    lines += ['', '**MongoDB EC2: the current instance and its root disk will be deleted. Back up any data before approving.**']
if args.summary:
    with Path(args.summary).open('a') as summary:
        summary.write('\n'.join(lines) + '\n\n')
print(f"Review required: {len(destructive)} resource(s) deleted or replaced.")
print(f'PASS: {len(managed)} managed resources; tags, private subnets, intended exposures, audit controls and write-only credentials checked.')
