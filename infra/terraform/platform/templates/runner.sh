#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl git jq unzip python3 docker.io libicu74
# Ubuntu 24.04 has no awscli APT candidate in this image. Use AWS's supported snap.
snap wait system seed.loaded
if ! snap list aws-cli >/dev/null 2>&1; then
  snap install aws-cli --classic
fi
# systemd runner jobs may not inherit /snap/bin in PATH.
ln -sfn /snap/bin/aws /usr/local/bin/aws
/usr/local/bin/aws --version
# Deployment only needs the client. Do not grant runner access to a Docker daemon.
systemctl disable --now docker.service docker.socket
systemctl enable --now snap.amazon-ssm-agent.amazon-ssm-agent.service
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"
curl -fsSLO https://dl.k8s.io/release/v1.35.0/bin/linux/amd64/kubectl
curl -fsSLO https://dl.k8s.io/release/v1.35.0/bin/linux/amd64/kubectl.sha256
printf '%s  kubectl\n' "$(cat kubectl.sha256)" | sha256sum -c -
install -m 0755 kubectl /usr/local/bin/kubectl
curl -fsSLO https://get.helm.sh/helm-v3.19.0-linux-amd64.tar.gz
curl -fsSLO https://get.helm.sh/helm-v3.19.0-linux-amd64.tar.gz.sha256sum
sha256sum -c helm-v3.19.0-linux-amd64.tar.gz.sha256sum
tar -xzf helm-v3.19.0-linux-amd64.tar.gz
install -m 0755 linux-amd64/helm /usr/local/bin/helm
curl -fsSL https://github.com/actions/runner/releases/download/v2.337.0/actions-runner-linux-x64-2.337.0.tar.gz -o runner.tar.gz
printf '%s  runner.tar.gz\n' 70920811a4f8ad4328818682bca5c6469c1c942fab52448868071d0063816613 | sha256sum -c -
install -d -o ubuntu -g ubuntu -m 0700 /opt/actions-runner
tar -xzf runner.tar.gz -C /opt/actions-runner
chown -R ubuntu:ubuntu /opt/actions-runner
/opt/actions-runner/bin/installdependencies.sh
# Ubuntu's sudo access is required by the workflow's Cimon action.
# Registration is deliberately interactive: no GitHub tokens in user_data/state.
cat > /usr/local/sbin/register-tasky-runner <<'REGISTER'
#!/bin/bash
set -euo pipefail
cd /opt/actions-runner
if [[ -f .runner ]]; then
  echo 'Runner already registered; refusing to overwrite its registration.' >&2
  exit 1
fi
read -r -s -p 'Paste the short-lived GitHub runner registration token: ' token
echo
sudo -u ubuntu ./config.sh --unattended --url https://github.com/Abdullah-Schahin/tasky \
  --token "$token" --name tasky-eks-deploy --labels tasky-eks --work _work
unset token
./svc.sh install ubuntu
./svc.sh start
REGISTER
chmod 0700 /usr/local/sbin/register-tasky-runner
touch /var/lib/tasky-runner-ready
