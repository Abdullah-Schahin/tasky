"""Deploy the verified image, then point the app's Route 53 alias at its ALB."""
import json
import os
from pathlib import Path
import re
import subprocess
import time
from terraform_ci import write_backend, verify_state_bucket


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def values(env):
    host = env.get('APP_DOMAIN', '')
    if host != 'tasky.abu-pse.link':
        raise ValueError('Set APP_DOMAIN to tasky.abu-pse.link')
    region, account = env['AWS_REGION'], env['AWS_ACCOUNT_ID']
    cert = env['ACM_CERTIFICATE_ARN']
    if not re.fullmatch(f'arn:aws:acm:{re.escape(region)}:{re.escape(account)}:certificate/[a-f0-9-]+', cert):
        raise ValueError('Certificate must be in the deployment account and ALB region')
    subnets = json.loads(env['PUBLIC_SUBNET_IDS'])
    if not isinstance(subnets, list) or len(set(subnets)) < 2 or not all(re.fullmatch(r'subnet-[a-f0-9]+', s) for s in subnets):
        raise ValueError('PUBLIC_SUBNET_IDS must contain at least two public subnet IDs')
    if not re.fullmatch(r'Z[A-Z0-9]+', env['APP_HOSTED_ZONE_ID']):
        raise ValueError('Invalid APP_HOSTED_ZONE_ID')
    if not re.fullmatch(r'sha256:[a-f0-9]{64}', env['IMAGE_DIGEST']):
        raise ValueError('Deployment requires a published image digest')
    image = env['IMAGE_REF'].rsplit(':', 1)[0] + '@' + env['IMAGE_DIGEST']
    if not re.fullmatch(r'ghcr\.io/[a-z0-9._/-]+@sha256:[a-f0-9]{64}', image):
        raise ValueError('Expected a digest-pinned GHCR image')
    return {'image': {'reference': image}, 'ingress': {'className': 'alb', 'host': host,
            'certificateArn': cert, 'publicSubnets': subnets}, 'clusterResources': {'create': False},
            'existingSecret': 'tasky-secrets', 'mongodbTLS': {'existingSecret': 'tasky-mongo-ca'}}


def main():
    env = os.environ
    config = values(env)
    cert = json.loads(run('aws','acm','describe-certificate','--certificate-arn',env['ACM_CERTIFICATE_ARN']))['Certificate']
    if cert['Status'] != 'ISSUED' or env['APP_DOMAIN'] not in cert['SubjectAlternativeNames']:
        raise ValueError('ACM certificate must be issued and cover APP_DOMAIN')
    temp = Path(env['RUNNER_TEMP'])
    helm_values = temp/'app-values.json'
    helm_values.write_text(json.dumps(config))
    context = 'tasky-ci-aws'
    run('aws','eks','update-kubeconfig','--name',env['EKS_CLUSTER_NAME'],'--region',env['AWS_REGION'],'--alias',context)
    subprocess.run(['helm','upgrade','--install','tasky','infra/helm/tasky','--namespace','tasky',
                    '--kube-context',context,'-f',str(helm_values),'--wait','--timeout','10m'],check=True)
    lb = None
    for _ in range(120):
        obj = json.loads(run('kubectl','--context',context,'-n','tasky','get','ingress','tasky','-o','json'))
        ingress = obj.get('status',{}).get('loadBalancer',{}).get('ingress',[])
        if ingress and ingress[0].get('hostname'):
            hostname = ingress[0]['hostname']
            lbs=json.loads(run('aws','elbv2','describe-load-balancers'))['LoadBalancers']
            matches=[item for item in lbs if item['DNSName']==hostname and item['Scheme']=='internet-facing' and item['Type']=='application']
            if len(matches)==1:
                candidate=matches[0]
                listeners=json.loads(run('aws','elbv2','describe-listeners','--load-balancer-arn',candidate['LoadBalancerArn']))['Listeners']
                if any(l['Protocol']=='HTTPS' and l['Port']==443 and any(c['CertificateArn']==env['ACM_CERTIFICATE_ARN'] for c in l.get('Certificates',[])) for l in listeners):
                    lb=candidate
                    break
        time.sleep(5)
    if lb is None:
        raise RuntimeError('Ingress ALB with the expected HTTPS certificate did not become ready within 10 minutes')
    dns_values=dict(account_id=env['AWS_ACCOUNT_ID'], region=env['AWS_REGION'],
                    hosted_zone_id=env['APP_HOSTED_ZONE_ID'],alb_arn=lb['LoadBalancerArn'])
    Path('infra/terraform/app-dns/ci.auto.tfvars.json').write_text(json.dumps(dns_values))
    verify_state_bucket(env)
    backend_file=temp/'app-dns-backend.hcl'
    write_backend(backend_file, env['TF_STATE_BUCKET'], 'app-dns/terraform.tfstate', env['AWS_REGION'], env['AWS_ACCOUNT_ID'])
    subprocess.run(['terraform','-chdir=infra/terraform/app-dns','init','-input=false','-lockfile=readonly',f'-backend-config={backend_file}'],check=True)
    plan=temp/'app-dns.tfplan'
    subprocess.run(['terraform','-chdir=infra/terraform/app-dns','plan','-input=false','-lock-timeout=5m',f'-out={plan}'],check=True)
    subprocess.run(['terraform','-chdir=infra/terraform/app-dns','apply','-input=false','-lock-timeout=5m',str(plan)],check=True)
    print('Application DNS configured: https://tasky.abu-pse.link')


if __name__ == '__main__':
    main()
