#!/usr/bin/env bash
# Worker only: join cluster using command generated on master

set -euo pipefail

if [[ -f /etc/kubernetes/kubelet.conf ]]; then
  echo "==> [worker] Already joined cluster, skipping"
  exit 0
fi

JOIN_CMD="${JOIN_CMD:-}"

if [[ -z "${JOIN_CMD}" && -f /vagrant/join-command.sh ]]; then
  JOIN_CMD=$(tr -d '\r' < /vagrant/join-command.sh)
fi

if [[ -z "${JOIN_CMD}" ]]; then
  echo "ERROR: No join command. Run ./bin/up.sh from your Mac"
  exit 1
fi

# Join command from master already uses private IP:6443 — run as-is (do not rewrite; that broke :6443)
if ! grep -qE 'kubeadm join [^ ]+:6443' <<<"${JOIN_CMD}"; then
  echo "ERROR: Invalid join command (expected host:6443): ${JOIN_CMD}"
  exit 1
fi

echo "==> [worker] Joining cluster via: $(echo "${JOIN_CMD}" | awk '{print $3}')"
eval "${JOIN_CMD}"

echo "==> [worker] Join complete"
