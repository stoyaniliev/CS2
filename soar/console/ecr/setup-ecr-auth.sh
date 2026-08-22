#!/bin/bash
# =============================================================================
# Give k3s a way to pull from ECR.
#
# The node's IAM role already carries the ECR pull permissions, but containerd
# does not use IAM directly. It needs a registry credential, and an ECR
# authorisation token expires after 12 hours, so a static secret would work
# today and fail tomorrow morning with ImagePullBackOff.
#
# This installs a systemd timer that mints a fresh token every 6 hours and
# writes it into a Kubernetes pull secret. Run once on the k3s node.
# =============================================================================

set -euo pipefail

REGION="${REGION:-eu-central-1}"
ACCOUNT="${ACCOUNT:-182460207849}"
REGISTRY="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"
NAMESPACES="${NAMESPACES:-soar default}"

sudo tee /usr/local/bin/refresh-ecr-secret.sh > /dev/null <<SCRIPT
#!/bin/bash
# Refresh the ECR pull secret in every namespace that needs it.
set -euo pipefail
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
export AWS_DEFAULT_REGION=${REGION}

TOKEN=\$(aws ecr get-login-password --region ${REGION})

for ns in ${NAMESPACES}; do
  kubectl create namespace "\$ns" --dry-run=client -o yaml | kubectl apply -f - > /dev/null
  kubectl -n "\$ns" create secret docker-registry ecr-credentials \\
    --docker-server=${REGISTRY} \\
    --docker-username=AWS \\
    --docker-password="\$TOKEN" \\
    --dry-run=client -o yaml | kubectl apply -f - > /dev/null
  echo "refreshed ecr-credentials in \$ns"
done
SCRIPT

sudo chmod +x /usr/local/bin/refresh-ecr-secret.sh

sudo tee /etc/systemd/system/ecr-secret.service > /dev/null <<'UNIT'
[Unit]
Description=Refresh the ECR pull secret for k3s
After=k3s.service
Wants=k3s.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/refresh-ecr-secret.sh
UNIT

# Every 6 hours against a 12 hour token lifetime, so a single missed run does
# not cause a pull failure.
sudo tee /etc/systemd/system/ecr-secret.timer > /dev/null <<'UNIT'
[Unit]
Description=Refresh the ECR pull secret every 6 hours

[Timer]
OnBootSec=2min
OnUnitActiveSec=6h
Persistent=true

[Install]
WantedBy=timers.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable --now ecr-secret.timer
sudo systemctl start ecr-secret.service

echo
echo "--- timer ---"
systemctl list-timers ecr-secret.timer --no-pager
echo
echo "--- secrets created ---"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
for ns in ${NAMESPACES}; do
  kubectl -n "$ns" get secret ecr-credentials 2>/dev/null || echo "missing in $ns"
done
