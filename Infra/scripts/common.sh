#!/usr/bin/env bash
# Shared setup on EVERY node (master + worker).

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# From .env via Vagrant: minor version for pkgs.k8s.io (e.g. 1.29)
K8S_VERSION="${K8S_VERSION:-1.29}"

echo "==> [common] Disable swap (required — kubelet refuses to run with swap on)"
swapoff -a
sed -i '/ swap / s/^\(.*\)$/#\1/' /etc/fstab

echo "==> [common] Load kernel modules for container networking"
cat >/etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

echo "==> [common] sysctl — enable iptables to see bridged traffic (CNI needs this)"
cat >/etc/sysctl.d/k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl -p /etc/sysctl.d/k8s.conf

echo "==> [common] Install containerd (CRI)"
apt-get update -qq
apt-get install -y -qq apt-transport-https ca-certificates curl gnupg lsb-release

apt-get install -y -qq containerd
mkdir -p /etc/containerd
containerd config default >/etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd

echo "==> [common] Install kubelet, kubeadm, kubectl (K8S_VERSION=${K8S_VERSION})"
mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" \
  >/etc/apt/sources.list.d/kubernetes.list

apt-get update -qq
apt-get install -y -qq kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
systemctl enable kubelet

echo "==> [common] Done — node is ready for kubeadm init or join"
