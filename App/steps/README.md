# Step-by-step guide — build and deploy

Walkthrough for the [PHP + NGINX demo](../README.md). Commands assume the working directory is **`App/`**.

## Overview

| Step | Action |
|------|--------|
| [1. Application](#step-1-application) | Review the PHP endpoint |
| [2. Container images](#step-2-container-images) | Build and push NGINX + PHP-FPM images |
| [3. Kubernetes](#step-3-deploy-to-kubernetes) | Apply manifests |
| [4. Verify](#step-4-verify) | Test client IP, HTTP, and Prometheus metrics |

### Prerequisites

- Cluster provisioned — [Infra/README.md](../../Infra/README.md)
- Observability stack installed — [Observability/README.md](../../Observability/README.md)
- `kubectl` context configured for the target cluster

---

## Step 1: Application

The application is a single PHP file that returns JSON showing how the client IP was detected.

**File:** `app/php-fpm/index.php`

**Response fields:**

| Field | Meaning |
|-------|---------|
| `client_ip` | Best guess of the real client (first IP in `X-Forwarded-For`, or `REMOTE_ADDR`) |
| `remote_addr` | Value PHP received as `REMOTE_ADDR` from NGINX |
| `x_forwarded_for` | Raw `X-Forwarded-For` header (for debugging) |
| `host` | Pod hostname (useful with multiple replicas) |

When traffic passes through a load balancer or proxy, the original client IP is usually in `X-Forwarded-For`. NGINX resolves it before FastCGI; PHP exposes the result for verification.

The PHP source is copied into the container image during Step 2 — no separate build step for the script itself.

---

## Step 2: Container images

Two images are required:

1. **php-fpm** — PHP 8.2 FPM + `index.php`
2. **nginx** — NGINX base image (runtime config is supplied by a Kubernetes ConfigMap)

### Build context

Both Dockerfiles use **`App/`** as the build context:

```bash
cd App
```

### Multi-arch build (recommended)

Use when the build host architecture differs from cluster nodes (e.g. ARM laptop, AMD64 nodes):

```bash
docker buildx create --name multi --use 2>/dev/null || docker buildx use multi
docker buildx inspect --bootstrap

docker buildx build --platform linux/amd64,linux/arm64 \
  -f app/php-fpm/Dockerfile \
  -t <registry>/php-fpm-ip-demo:latest \
  --push .

docker buildx build --platform linux/amd64,linux/arm64 \
  -f app/nginx/Dockerfile \
  -t <registry>/nginx-ip-demo:latest \
  --push .
```

### Single-arch build (local testing)

```bash
docker build -f app/php-fpm/Dockerfile -t <registry>/php-fpm-ip-demo:latest .
docker build -f app/nginx/Dockerfile -t <registry>/nginx-ip-demo:latest .
docker push <registry>/php-fpm-ip-demo:latest
docker push <registry>/nginx-ip-demo:latest
```

### Update Kubernetes manifests

Set image references in:

- `k8s/01-php-fpm-deployment.yaml`
- `k8s/04-nginx-deployment.yaml`

Example:

```yaml
image: <registry>/php-fpm-ip-demo:latest
```

---

## Step 3: Deploy to Kubernetes

### Configure external access (bare-metal / VPS)

Edit `k8s/05-nginx-service.yaml` and set `externalIPs` to the **worker node IP** (where NGINX pods are scheduled):

```yaml
externalIPs:
  - <worker-ip>
```

On cloud clusters with a real load balancer, the `EXTERNAL-IP` from `kubectl get svc` can be used instead.

### Apply manifests

```bash
kubectl apply -f k8s/
```

Manifests are numbered `00`–`11`:

| File | Creates |
|------|---------|
| `00-namespace.yaml` | Namespace `php-nginx-demo` |
| `01-php-fpm-deployment.yaml` | PHP-FPM Deployment |
| `02-php-fpm-service.yaml` | ClusterIP Service for FastCGI |
| `03-nginx-configmap.yaml` | NGINX config (`real_ip`, FastCGI, `stub_status`) |
| `04-nginx-deployment.yaml` | NGINX + **log exporter sidecar** |
| `05-nginx-service.yaml` | LoadBalancer + `externalIPs` |
| `06-nginx-exporter-deployment.yaml` | **stub_status exporter** (separate pod) |
| `07-nginx-exporter-service.yaml` | Metrics Service for stub_status exporter |
| `08-nginx-exporter-servicemonitor.yaml` | Prometheus scrape config |
| `09-nginx-log-exporter-configmap.yaml` | Log exporter config |
| `10-nginx-log-metrics-service.yaml` | Metrics Service for log exporter sidecar |
| `11-nginx-log-servicemonitor.yaml` | Prometheus scrape config |

### Check rollout

```bash
kubectl get all -n php-nginx-demo
kubectl get svc -n php-nginx-demo
kubectl get servicemonitor -n php-nginx-demo
```

All pods should reach `Running`; Services should have endpoints.

---

## Step 4: Verify

### 4.1 Application and client IP

**Cloud cluster** — LoadBalancer external IP:

```bash
kubectl get svc nginx -n php-nginx-demo
curl http://<EXTERNAL-IP>/
```

**Bare-metal / VPS** — `externalIPs` from `05-nginx-service.yaml`:

```bash
curl http://<worker-ip>/
```

Expected: JSON with `client_ip`, `remote_addr`, `x_forwarded_for`.

**Forwarded header test:**

```bash
curl -H "X-Forwarded-For: 8.8.8.8" http://<worker-ip>/
```

Expected: `"client_ip": "8.8.8.8"`.

#### Troubleshooting curl

1. Re-apply the Service after changing `externalIPs`:
   ```bash
   kubectl apply -f k8s/05-nginx-service.yaml
   ```
2. Ensure port 80 is open on the worker (cloud firewall, `ufw`, security groups).
3. Port-forward bypass (confirms the app without LB):
   ```bash
   kubectl port-forward -n php-nginx-demo svc/nginx 8080:80
   curl http://127.0.0.1:8080/
   ```

### 4.2 Monitoring — stub_status exporter

The separate pod scrapes NGINX connection metrics over HTTP:

```bash
kubectl port-forward -n php-nginx-demo svc/nginx-exporter 9113:9113
curl http://127.0.0.1:9113/metrics | grep nginx_connections
```

Expected metrics include `nginx_up`, `nginx_connections_active`, `nginx_connections_reading`.

### 4.3 Monitoring — access-log exporter (sidecar)

The sidecar parses NGINX access logs for HTTP status codes:

```bash
kubectl port-forward -n php-nginx-demo svc/nginx-log-metrics 4040:4040
curl http://127.0.0.1:4040/metrics | grep nginx_http_response_count_total
```

### 4.4 Test 5xx metrics

Scale PHP-FPM to zero so NGINX returns 502:

```bash
kubectl scale deployment php-fpm -n php-nginx-demo --replicas=0
curl -i http://<worker-ip>/

kubectl port-forward -n php-nginx-demo svc/nginx-log-metrics 4040:4040
curl -s http://127.0.0.1:4040/metrics | grep 'status="502"'

kubectl scale deployment php-fpm -n php-nginx-demo --replicas=1
```

### 4.5 Prometheus targets

With Observability installed, port-forward to Prometheus:

```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
```

Open http://localhost:9090/targets — `php-nginx-demo` jobs should show **UP**.

PromQL example:

```promql
sum(rate(nginx_http_response_count_total{status=~"5.."}[5m]))
```

---

## Further reading

- [../README.md](../README.md) — architecture and design rationale
- [../tuning-readme.md](../tuning-readme.md) — resource sizing
- [../../Observability/README.md](../../Observability/README.md) — Prometheus stack
