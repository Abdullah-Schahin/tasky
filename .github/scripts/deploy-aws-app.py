"""Deploy the verified image, then report the HTTP-only demo ALB address."""
import json
import os
from pathlib import Path
import re
import subprocess
import time


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def values(env):
    subnets = json.loads(env['PUBLIC_SUBNET_IDS'])
    if not isinstance(subnets, list) or len(set(subnets)) < 2 or not all(re.fullmatch(r'subnet-[a-f0-9]+', s) for s in subnets):
        raise ValueError('PUBLIC_SUBNET_IDS must contain at least two public subnet IDs')
    if not re.fullmatch(r'sha256:[a-f0-9]{64}', env['IMAGE_DIGEST']):
        raise ValueError('Deployment requires a published image digest')
    image = env['IMAGE_REF'].rsplit(':', 1)[0] + '@' + env['IMAGE_DIGEST']
    repository = env.get('IMAGE_NAME', 'tasky-wiz/tasky')
    registry = f"{env['AWS_ACCOUNT_ID']}.dkr.ecr.{env['AWS_REGION']}.amazonaws.com"
    if not re.fullmatch(r'[a-z0-9]+(?:[._/-][a-z0-9]+)*', repository) or image != f"{registry}/{repository}@{env['IMAGE_DIGEST']}":
        raise ValueError('Expected a digest-pinned image from the configured account/region ECR repository')
    return {'image': {'reference': image}, 'ingress': {'className': 'alb', 'host': '', 'publicSubnets': subnets}, 'clusterResources': {'create': False},
            'existingSecret': 'tasky-secrets', 'mongodbTLS': {'existingSecret': 'tasky-mongo-ca'}}


def main():
    env = os.environ
    config = values(env)
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
                if any(l['Protocol']=='HTTP' and l['Port']==80 for l in listeners) and not any(l['Protocol']=='HTTPS' for l in listeners):
                    lb=candidate
                    break
        time.sleep(5)
    if lb is None:
        raise RuntimeError('Ingress ALB with the expected HTTP-only listener did not become ready within 10 minutes')
    address = f"http://{lb['DNSName']}"
    print('Application demo URL: ' + address)
    with open(env.get('GITHUB_STEP_SUMMARY', os.devnull), 'a') as summary:
        summary.write(f"## Application demo URL\n\n{address}\n\n")
        summary.write('Intentional exercise weakness: HTTP without TLS; credentials, session tokens and application data are unencrypted in transit. Use synthetic demo data only.\n')



if __name__ == '__main__':
    main()
