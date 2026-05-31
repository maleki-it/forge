#!/usr/bin/env bash
# Control plane: kubeadm init + Flannel CNI

set -euo pipefail

WORKER_NODE="${WORKER_NODE:-true}"
KUBERNETES_VERSION="${KUBERNETES_VERSION:-}"

get_private_ip() {
  local ip
  ip=$(curl -sf http://169.254.169.254/metadata/v1/interfaces/private/0/ipv4/address 2>/dev/null || true)
  if [[ -n "${ip}" ]]; then
    echo "${ip}"
    return
  fi
  hostname -I | tr ' ' '\n' | grep -E '^10\.' | head -1
}

get_public_ip() {
  curl -sf http://169.254.169.254/metadata/v1/interfaces/public/0/ipv4/address 2>/dev/null || true
}

PRIVATE_IP=$(get_private_ip)
PUBLIC_IP=$(get_public_ip)

if [[ -z "${PRIVATE_IP}" ]]; then
  echo "ERROR: Could not detect private IP"
  exit 1
fi

if [[ -z "${KUBERNETES_VERSION}" ]]; then
  KUBERNETES_VERSION=$(kubeadm version -o short 2>/dev/null | sed 's/^v//')
fi
if [[ -z "${KUBERNETES_VERSION}" ]]; then
  echo "ERROR: Set KUBERNETES_VERSION in .env (e.g. 1.29.15)"
  exit 1
fi

if [[ ! -f /etc/kubernetes/admin.conf ]]; then
  echo "==> [master] kubeadm init (version v${KUBERNETES_VERSION}, API ${PRIVATE_IP}:6443)"
  # Include public IP in apiserver cert SAN so kubectl from your Mac can verify TLS.
  # Without this, rewriting kubeconfig server to public IP causes x509 mismatch.
  KUBEADM_ARGS=(
    "--kubernetes-version=v${KUBERNETES_VERSION}"
    "--apiserver-advertise-address=${PRIVATE_IP}"
    "--pod-network-cidr=10.244.0.0/16"
    "--node-name=k8s-master"
    "--control-plane-endpoint=${PRIVATE_IP}:6443"
  )
  if [[ -n "${PUBLIC_IP}" ]]; then
    KUBEADM_ARGS+=("--apiserver-cert-extra-sans=${PUBLIC_IP}")
  fi
  kubeadm init "${KUBEADM_ARGS[@]}"
else
  echo "==> [master] Cluster already initialized, continuing post-init setup"
fi

echo "==> [master] kubectl config for root"
mkdir -p /root/.kube
cp -f /etc/kubernetes/admin.conf /root/.kube/config
chown root:root /root/.kube/config

if id vagrant &>/dev/null; then
  mkdir -p /home/vagrant/.kube
  cp -f /etc/kubernetes/admin.conf /home/vagrant/.kube/config
  chown vagrant:vagrant /home/vagrant/.kube/config
fi

export KUBECONFIG=/etc/kubernetes/admin.conf

echo "==> [master] Install Flannel CNI"
if kubectl get namespace kube-flannel &>/dev/null; then
  echo "==> [master] Flannel already installed"
else
  kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
fi

echo "==> [master] Wait until control plane is Ready"
kubectl wait --for=condition=Ready node/k8s-master --timeout=300s || true

mkdir -p /vagrant
echo "${PRIVATE_IP}" >/vagrant/master-private-ip.txt
echo "${PUBLIC_IP}" >/vagrant/master-public-ip.txt

case "${WORKER_NODE}" in
  true|1|yes|TRUE|Yes)
    echo "==> [master] Save join command for worker (private IP)"
    JOIN_CMD=$(kubeadm token create --print-join-command --ttl 24h)
    echo "${JOIN_CMD}" >/root/join-command.sh
    chmod 644 /root/join-command.sh
    echo "${JOIN_CMD}" >/vagrant/join-command.sh
    echo "==> [master] Private IP (worker join): ${PRIVATE_IP}"
    ;;
  *)
    echo "==> [master] Single-node cluster (WORKER_NODE=false) — allow pods on control plane"
    kubectl taint nodes k8s-master node-role.kubernetes.io/control-plane:NoSchedule- 2>/dev/null || true
    rm -f /root/join-command.sh /vagrant/join-command.sh 2>/dev/null || true
    echo "==> [master] No worker droplet — join command not created"
    ;;
esac

echo "==> [master] Public IP (kubectl from Mac): ${PUBLIC_IP:-unknown}"
