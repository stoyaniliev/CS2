#!/bin/bash
set -euxo pipefail
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

apt-get update -y
apt-get install -y curl jq unzip apt-transport-https

# --- k3s ---------------------------------------------------------------------
# Traefik disabled: NodePort is sufficient here and Traefik would add an
# unneeded ingress layer to reason about.
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable=traefik --write-kubeconfig-mode=644" sh -

until kubectl get nodes 2>/dev/null | grep -q " Ready "; do
  echo "waiting for k3s node to become Ready"; sleep 5
done

# --- Helm ---------------------------------------------------------------------
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' >> /home/ubuntu/.bashrc

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace soar       --dry-run=client -o yaml | kubectl apply -f -

# --- AWS CLI, for the SOAR components running in-cluster -----------------------
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp && /tmp/aws/install

touch /var/lib/cloud/k3s-bootstrap-complete
echo "k3s bootstrap complete" | logger -t user-data
