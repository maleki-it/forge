#!/usr/bin/env bash
# Bring up cluster from .env (WORKER_NODE=true|false, K8S_VERSION, etc.)

set -euo pipefail
cd "$(dirname "$0")/.."

if [[ ! -f .env ]]; then
  echo "Create .env from .env.example and set DO_API_TOKEN"
  exit 1
fi

set -a
# shellcheck source=/dev/null
source .env
set +a

worker_enabled() {
  case "${WORKER_NODE:-true}" in
    true|1|yes|TRUE|Yes|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

export VAGRANT_NO_PARALLEL=1

echo "=== Config ==="
echo "  K8S_VERSION=${K8S_VERSION:-1.29}"
echo "  KUBERNETES_VERSION=${KUBERNETES_VERSION:-auto}"
echo "  WORKER_NODE=${WORKER_NODE:-true}"
echo ""

echo "=== Step 1: Create master and provision Kubernetes ==="
vagrant up master --provider=digital_ocean

vagrant ssh master -c "sudo cat /vagrant/master-public-ip.txt" > master-public-ip.txt 2>/dev/null \
  || vagrant ssh master -c "curl -sf http://169.254.169.254/metadata/v1/interfaces/public/0/ipv4/address" > master-public-ip.txt

if worker_enabled; then
  echo "=== Step 2: Copy join command from master ==="
  vagrant ssh master -c "sudo cat /root/join-command.sh" > join-command.sh
  vagrant ssh master -c "sudo cat /vagrant/master-private-ip.txt" > master-private-ip.txt

  echo "=== Step 3: Create worker and join cluster ==="
  vagrant up worker --provider=digital_ocean --no-provision

  export JOIN_CMD
  JOIN_CMD=$(tr -d '\r' < join-command.sh)
  vagrant provision worker
else
  echo "=== WORKER_NODE=false — skipping worker droplet and join ==="
  rm -f join-command.sh master-private-ip.txt 2>/dev/null || true
fi

echo ""
echo "=== Done ==="
PUBLIC_IP=$(tr -d '\r' < master-public-ip.txt)
echo "Master public IP: ${PUBLIC_IP}"
if worker_enabled; then
  echo "Nodes: master + worker"
else
  echo "Nodes: single-node (master only, ~half the cost)"
fi
echo "Next: ./bin/kubeconfig.sh   then   kubectl get nodes"
