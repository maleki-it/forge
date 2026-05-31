# Kubernetes lab on DigitalOcean (Vagrant + kubeadm)

Provision a small Kubernetes cluster on [DigitalOcean](https://www.digitalocean.com/) droplets using [Vagrant](https://www.vagrantup.com/) and [kubeadm](https://kubernetes.io/docs/reference/setup-tools/kubeadm/). Nodes run **Ubuntu 22.04**, **containerd** (CRI), and **Flannel** (CNI).

Configuration is driven by a local `.env` file: Kubernetes version, region, SSH key, and whether to create a separate worker node.

## Features

- One or two droplets (`s-2vcpu-4gb`: 2 vCPU, 4 GiB RAM each)
- Automated control-plane setup and optional worker join
- `kubectl` access from your workstation via a patched kubeconfig
- Helper scripts for create, kubeconfig export, and destroy

## Cluster sizes and cost

| `WORKER_NODE` | Droplets | Approx. monthly cost |
|---------------|----------|----------------------|
| `true` | master + worker | ~$48 (2 × ~$24) |
| `false` | master only (single-node) | ~$24 |

| VM | Role | Created when |
|----|------|--------------|
| `master` | Control plane | Always |
| `worker` | Worker node | `WORKER_NODE=true` |

**Important:** Droplets are billed while they exist. Run `./bin/destroy.sh` when you are done to stop charges.

## Requirements

### Accounts and keys

1. A [DigitalOcean](https://cloud.digitalocean.com/) account
2. An API token with read and write access: [API tokens](https://cloud.digitalocean.com/account/api/tokens)
3. An SSH key pair on your machine, registered in DigitalOcean under **Settings → Security → SSH Keys**

The Vagrant DigitalOcean plugin expects:

- Private key: e.g. `~/.ssh/id_rsa` (or `id_ed25519`)
- Public key: same path with `.pub` appended (e.g. `~/.ssh/id_rsa.pub`)

Do **not** commit `.env` or API tokens to git.

### Workstation software

You need **Vagrant**, the **vagrant-digitalocean** plugin, and an **SSH client**. Ruby is bundled with official Vagrant packages.

#### macOS

Install [Homebrew](https://brew.sh/) if needed, then:

```bash
brew install vagrant
vagrant plugin install vagrant-digitalocean
```

OpenSSH is included with macOS.

#### Linux (Debian / Ubuntu)

```bash
# Vagrant (HashiCorp apt repo)
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install -y vagrant

vagrant plugin install vagrant-digitalocean
```

OpenSSH client:

```bash
sudo apt install -y openssh-client
```

#### Linux (Fedora / RHEL / Rocky / Alma)

```bash
sudo dnf install -y dnf-plugins-core
sudo dnf config-manager --add-repo https://rpm.releases.hashicorp.com/fedora/hashicorp.repo
sudo dnf install -y vagrant

vagrant plugin install vagrant-digitalocean
sudo dnf install -y openssh-clients
```

#### Linux (Arch)

```bash
# Vagrant is in community repos; plugin install is the same
sudo pacman -S vagrant openssh
vagrant plugin install vagrant-digitalocean
```

#### Verify installation

```bash
vagrant --version
vagrant plugin list | grep digitalocean
ssh -V
```

## Project layout

```
Infra/
├── Vagrantfile              # Droplet definitions and provisioning hooks
├── scripts/
│   ├── common.sh            # All nodes: swap, kernel, containerd, kubeadm packages
│   ├── master.sh            # Control plane: kubeadm init + Flannel
│   └── worker.sh            # Worker: kubeadm join
├── bin/
│   ├── up.sh                # Create master, then worker (if enabled)
│   ├── kubeconfig.sh        # Export admin kubeconfig for local kubectl
│   └── destroy.sh           # Delete droplets
├── .env.example             # Configuration template
└── README.md
```

## Quick start

### 1. Configure environment

```bash
cd Infra
cp .env.example .env
```

Edit `.env`:

```bash
DO_API_TOKEN=your_digitalocean_token_here
SSH_PRIVATE_KEY_PATH=~/.ssh/id_rsa
DO_SSH_KEY_NAME=your-do-ssh-key-name

# Kubernetes (apt repo minor + kubeadm init exact version)
K8S_VERSION=1.34
KUBERNETES_VERSION=1.34.8

# true = 2 droplets | false = 1 droplet (cheaper, no worker join)
WORKER_NODE=true
```

| Variable | Purpose |
|----------|---------|
| `DO_API_TOKEN` | DigitalOcean API token |
| `DO_REGION` | Droplet region (default: `nyc1`) |
| `SSH_PRIVATE_KEY_PATH` | Path to your SSH private key |
| `DO_SSH_KEY_NAME` | Name of the key in your DigitalOcean account |
| `K8S_VERSION` | Minor version for apt packages (`kubelet`, `kubeadm`, `kubectl`), e.g. `1.34` |
| `KUBERNETES_VERSION` | Exact patch for `kubeadm init`, e.g. `1.34.8` — see [Kubernetes releases](https://kubernetes.io/releases/) |
| `WORKER_NODE` | `true` → master + worker; `false` → single-node cluster |

Optional region override:

```bash
DO_REGION=sfo3
```

On Linux, expand `~` in `SSH_PRIVATE_KEY_PATH` or use a full path such as `/home/you/.ssh/id_ed25519`.

### 2. Make scripts executable

```bash
chmod +x bin/*.sh scripts/*.sh
```

### 3. Create the cluster

```bash
./bin/up.sh
```

**What happens:**

1. **`vagrant up master`** — Creates the control-plane droplet.
2. **`scripts/common.sh`** — On each node:
   - Disables swap (required by kubelet)
   - Loads `overlay` and `br_netfilter` kernel modules
   - Applies sysctl settings for pod networking
   - Installs **containerd**
   - Installs **kubeadm**, **kubelet**, and **kubectl** (version from `K8S_VERSION`)
3. **`scripts/master.sh`** — Runs `kubeadm init`, installs **Flannel** (`10.244.0.0/16`), writes the join command.
4. **`vagrant up worker`** — Creates the worker droplet (when `WORKER_NODE=true`).
5. **`vagrant provision worker`** — Joins the worker to the cluster.

Expect **10–20 minutes** on first run (image pull and package installs). Single-node mode is faster and cheaper.

### 4. Configure kubectl locally

```bash
./bin/kubeconfig.sh
export KUBECONFIG=$HOME/.kube/config-k8s-vagrant
kubectl get nodes
```

You should see `k8s-master` (and `k8s-worker` if enabled) in `Ready` state within a few minutes.

The API server listens on the droplet **private** VPC address. `kubeconfig.sh` rewrites the server URL to the droplet **public** IP so `kubectl` works from outside DigitalOcean’s network.

| Traffic | IP used |
|---------|---------|
| Worker → master (`kubeadm join`) | Private `10.x.x.x:6443` (VPC) |
| Workstation → API (`kubectl`) | Public droplet IP `:6443` |

### 5. Try the cluster

```bash
kubectl get nodes -o wide
kubectl get pods -A
kubectl run demo --image=nginx --restart=Never
kubectl get pod demo
kubectl delete pod demo
```

SSH into a node:

```bash
vagrant ssh master
vagrant ssh worker   # when WORKER_NODE=true
```

## Shut down (stop billing)

When the lab is no longer needed, destroy the droplets.

### Option A — Script (recommended)

```bash
./bin/destroy.sh
```

Type `yes` when prompted.

### Option B — Vagrant

```bash
vagrant destroy -f master
vagrant destroy -f worker   # if WORKER_NODE=true
```

### Option C — DigitalOcean console

Delete droplets named like `k8s-vagrant_master_*` and `k8s-vagrant_worker_*` at [Droplets](https://cloud.digitalocean.com/droplets).

Confirm billing has stopped under [Billing](https://cloud.digitalocean.com/billing).

## Troubleshooting

| Problem | What to try |
|---------|-------------|
| `Missing DO_API_TOKEN` | Create `.env` from `.env.example` and set the token |
| `SSH private key not found` | Set `SSH_PRIVATE_KEY_PATH` in `.env` to your key path |
| `SSH public key not found` | Ensure `your_key.pub` exists next to your private key |
| `Set DO_SSH_KEY_NAME in .env` | Match the name shown in DigitalOcean → SSH Keys |
| `SSH Key is already in use` (422) | Use a unique `DO_SSH_KEY_NAME` or reuse the existing key name |
| Worker did not join | `export JOIN_CMD=$(cat join-command.sh); vagrant provision worker` |
| `kubectl` timeout from workstation | Re-run `./bin/kubeconfig.sh`; confirm the master droplet is running |
| Plugin errors | `vagrant plugin install vagrant-digitalocean` |
| sysctl `Invalid argument` on master | Usually harmless on Ubuntu; only `k8s.conf` sysctl values are applied |

Kubelet logs on a node:

```bash
vagrant ssh master -c "sudo journalctl -u kubelet -n 50 --no-pager"
```

## Design notes

| Choice | Rationale |
|--------|-----------|
| **DigitalOcean** | Real cloud VMs; no local hypervisor required (works on Apple Silicon and Linux alike) |
| **Two-node max** | Keeps cost low while still demonstrating multi-node scheduling |
| **s-2vcpu-4gb** | Small but usable for demos and learning workloads |
| **Ubuntu 22.04 LTS** | Stable base for kubeadm |
| **containerd** | Default CRI for modern kubeadm clusters |
| **Flannel** | Simple CNI with a single manifest |
| **Private networking** | Worker joins the control plane over the VPC |
| **`bin/up.sh`** | Ensures the join token exists before the worker is provisioned |

## Security

- Keep `.env` local; it is listed in `.gitignore`.
- If an API token is exposed, revoke it in the DigitalOcean panel and create a new one.
- This setup is for **labs and learning**, not production. The control-plane API is reachable on the public IP after `kubeconfig.sh`.

## License

Part of the [forge](../) repository. Use and adapt freely; contributions welcome.
