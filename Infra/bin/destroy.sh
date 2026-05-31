#!/usr/bin/env bash
# Destroy droplets — stops billing

set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -f .env ]]; then
  set -a
  # shellcheck source=/dev/null
  source .env
  set +a
fi

worker_enabled() {
  case "${WORKER_NODE:-true}" in
    true|1|yes|TRUE|Yes|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

if worker_enabled; then
  echo "This will DELETE master + worker droplets."
else
  echo "This will DELETE the master droplet (WORKER_NODE=false)."
fi
read -r -p "Type 'yes' to continue: " confirm
if [[ "${confirm}" != "yes" ]]; then
  echo "Aborted."
  exit 1
fi

vagrant destroy -f master
if worker_enabled; then
  vagrant destroy -f worker 2>/dev/null || true
fi

rm -f join-command.sh master-private-ip.txt master-public-ip.txt 2>/dev/null || true

echo ""
echo "Droplets destroyed: https://cloud.digitalocean.com/droplets"
