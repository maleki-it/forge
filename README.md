# Forge

End-to-end Kubernetes lab: provision a cluster, install observability, deploy a PHP + NGINX application with Prometheus metrics.

Four modules — each with its own README, manifests, and architecture diagram.

## Overview

```mermaid
flowchart TB
    subgraph Workstation
        Dev["Vagrant / kubectl / Helm / Docker"]
    end

    subgraph Infra["Infra — cluster"]
        DO["DigitalOcean droplets"]
        Master["Control plane<br/>kubeadm + Flannel"]
        Worker["Worker node<br/>2 CPU / 4 GiB"]
        DO --> Master
        DO --> Worker
        Master --> Worker
    end

    subgraph Observability["Observability — monitoring"]
        Helm["kube-prometheus-stack"]
        Op["Prometheus Operator"]
        Prom["Prometheus + Grafana"]
        Helm --> Op --> Prom
    end

    subgraph App["App — workload"]
        Client["HTTP client"]
        CDN["CDN proxy<br/>Cloudflare / ArvanCloud"]
        Nginx["NGINX + log exporter"]
        PHP["PHP-FPM"]
        Stub["stub_status exporter"]
        SM["ServiceMonitors"]
        Client --> CDN --> Nginx --> PHP
        Stub --> Nginx
        Nginx --> SM
        Stub --> SM
    end

    Dev -->|"1. bin/up.sh"| Infra
    Dev -->|"2. helm install"| Observability
    Dev -->|"3. kubectl apply"| App
    Worker --> Observability
    Worker --> App
    SM -->|"scrape"| Prom

    subgraph SRE["SRE — reliability"]
        Fail["Failure simulation"]
        Alert["PrometheusRule"]
        PM["Postmortem"]
        Fail --> Alert --> PM
    end

    Dev -->|"4. simulate & document"| SRE
    Alert --> Prom
```

## Recommended order

| Step | Module | Action |
|------|--------|--------|
| 1 | [Infra/](Infra/) | Provision Kubernetes on DigitalOcean (Vagrant + kubeadm) |
| 2 | [Observability/](Observability/) | Install Prometheus, Grafana, and ServiceMonitor CRDs |
| 3 | [App/](App/) | Build images, deploy PHP + NGINX, verify metrics |
| 4 | [SRE/](SRE/) | Simulate failure, deploy alerts, write postmortem |

## Project READMEs

| Directory | Contents |
|-----------|----------|
| **[Infra/README.md](Infra/README.md)** | Cluster provisioning, `.env` config, `kubectl` access, teardown |
| **[Observability/README.md](Observability/README.md)** | kube-prometheus-stack, QoS, ServiceMonitor contract |
| **[App/README.md](App/README.md)** | Application architecture, design decisions, monitoring rationale |
| **[App/steps/README.md](App/steps/README.md)** | Build images, deploy manifests, verify client IP and metrics |
| **[App/tuning-readme.md](App/tuning-readme.md)** | PHP-FPM, NGINX, and Kubernetes resource sizing |
| **[SRE/README.md](SRE/README.md)** | Failure simulation, alert strategy, blameless postmortem |

## What each layer covers

| Layer | Topics |
|-------|--------|
| **Infra** | DigitalOcean droplets, kubeadm, containerd, Flannel, private VPC join, kubeconfig |
| **Observability** | Prometheus Operator, open ServiceMonitor selectors, resource limits / QoS |
| **App** | PHP-FPM + NGINX, client IP via `X-Forwarded-For`, CDN proxy to origin, dual exporters (log sidecar + stub_status pod) |
| **SRE** | Controlled 502 simulation, Prometheus alerts, Alertmanager, example postmortem |

## Live demo (CDN)

The deployed app responds on CDN-fronted domains with JSON showing `client_ip`, `remote_addr`, and `x_forwarded_for` — useful for verifying proxy headers through Cloudflare and ArvanCloud.

See **[App/README.md — CDN and proxy path](App/README.md#cdn-and-proxy-path)** for architecture diagram, example `curl` output (VPN on/off), and field explanations.

## Quick links

```bash
# 1 — Cluster (from Infra/)
./bin/up.sh && ./bin/kubeconfig.sh

# 2 — Monitoring (from Observability/)
kubectl create namespace monitoring
helm upgrade --install kube-prometheus-stack ./charts/kube-prometheus-stack \
  -n monitoring -f values.yaml --wait

# 3 — Application (from App/, after images are built)
kubectl apply -f k8s/

# 4 — SRE (alerts + failure drill)
kubectl apply -f SRE/alerts/php-nginx-demo-rules.yaml
# see SRE/runbooks/simulate-failure.md
```

Details, prerequisites, and troubleshooting live in each module README.

## License

Open source — use and adapt freely; contributions welcome.
