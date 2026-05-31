#!/usr/bin/env bash
# Copy admin kubeconfig to your Mac so kubectl works locally

set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p "$HOME/.kube"
vagrant ssh master -c "sudo cat /etc/kubernetes/admin.conf" > /tmp/k8s-vagrant-admin.conf

# Replace internal API URL with public IP so kubectl from Mac can reach the API
PUBLIC_IP=$(vagrant ssh master -c "curl -sf http://169.254.169.254/metadata/v1/interfaces/public/0/ipv4/address" 2>/dev/null | tr -d '\r')
if [[ -n "${PUBLIC_IP}" ]]; then
  sed "s|server: https://.*:6443|server: https://${PUBLIC_IP}:6443|" /tmp/k8s-vagrant-admin.conf > "$HOME/.kube/config-k8s-vagrant"
  echo "Wrote $HOME/.kube/config-k8s-vagrant"
  echo "Run: export KUBECONFIG=$HOME/.kube/config-k8s-vagrant"
else
  cp /tmp/k8s-vagrant-admin.conf "$HOME/.kube/config-k8s-vagrant"
  echo "Wrote $HOME/.kube/config-k8s-vagrant (you may need to fix the server IP manually)"
fi
