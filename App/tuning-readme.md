# Tuning guide — PHP, NGINX, and Kubernetes

This document explains **how to think about tuning** on any cluster, then applies it to **this lab setup**:

| Node | Spec | Role |
|---|---|---|
| Master | (control plane) | API, scheduler — usually no app pods |
| Worker | **2 CPU / 5 GiB RAM** | App + kube-prometheus-stack + system pods |

The demo app is tiny (`app/php-fpm/index.php`), but the **same method** applies to heavier PHP apps.

---

## 1. Golden rule: measure, then tune

Never copy random `pm.max_children` values from the internet.

1. Deploy with conservative limits.
2. Generate load (see [§7 Load testing](#7-load-testing)).
3. Watch **actual** usage:
   ```bash
   kubectl top pods -n php-nginx-demo
   kubectl top pods -n monitoring          # monitoring namespace
   kubectl describe node <worker-name>     # allocatable vs capacity
   ```
4. Adjust one knob at a time (PHP-FPM pool, replicas, CPU limit, etc.).
5. Re-test.

Skipping measurement leads to wasted RAM or OOM-killed pods under load.

---

## 2. Memory budget

On a single worker, **everything shares the same 5 GiB**.

Rough planning table (adjust after `kubectl top` on the cluster):

| Consumer | Typical RAM on this lab | Notes |
|---|---|---|
| Linux + kubelet + CNI | ~400–700 MiB | Always reserved |
| kube-prometheus-stack | ~1.5–2.5 GiB | Grafana ~1 GiB limit, Prometheus ~1 GiB, rest smaller |
| NGINX pod (2 containers) | ~50–150 MiB | Light for this demo |
| nginx-exporter pod | ~20–40 MiB | Optional; remove to save a pod |
| **PHP-FPM (application)** | **what’s left** | Main tunable workload |
| Headroom (10–15%) | ~300–500 MiB | Avoid running node at 100% |

**Example math for this worker:**

```
Total RAM:           5120 MiB
System + K8s:        - 600 MiB
Promstack (estimate): - 2000 MiB
NGINX + exporters:   - 150 MiB
Headroom:            - 400 MiB
─────────────────────────────
Available for PHP:   ~1970 MiB   (upper bound — verify with metrics!)
```

In practice, start PHP with **256–512 MiB limit** until RSS is measured. Avoid allocating all theoretical free RAM — other pods spike during compactions, scrapes, and dashboard use.

---

## 3. PHP-FPM pool tuning

PHP-FPM runs a **pool of worker processes**. Each concurrent request needs one worker.

### Key settings (`www.conf` or custom pool file)

| Setting | Meaning |
|---|---|
| `pm` | `static`, `dynamic`, or `ondemand` |
| `pm.max_children` | Hard cap on concurrent PHP processes |
| `pm.start_servers` | Processes at startup (`dynamic` only) |
| `pm.min_spare_servers` | Idle workers kept ready (`dynamic`) |
| `pm.max_spare_servers` | Max idle workers (`dynamic`) |
| `pm.max_requests` | Recycle worker after N requests (reduces memory leaks) |

### Choosing `pm` mode

| Mode | When to use |
|---|---|
| **dynamic** | Default choice for web apps with variable traffic |
| **static** | Predictable load; fixed memory footprint |
| **ondemand** | Very low traffic, save RAM (slower first request) |

For this demo on a small node: **`dynamic`** is a good default.

### The max_children formula

```
pm.max_children ≈ (PHP memory limit for the pod) / (average RAM per PHP process)
```

**Measure average RAM per process:**

```bash
# While under load:
kubectl exec -n php-nginx-demo deploy/php-fpm -- ps -o rss,command | grep php
# RSS is in KB; divide by 1024 for MiB
```

For Alpine PHP 8.2 running this JSON script, expect **~25–45 MiB** per worker.  
Heavier frameworks (Laravel, WordPress) often need **80–150 MiB+** per worker — measure the actual application.

**Example (this cluster, 512 MiB pod limit, ~40 MiB/worker):**

```
512 / 40 ≈ 12  →  use pm.max_children = 10  (leave margin)
```

If `pm.max_children` is too high → **OOMKill** on the pod or node.  
If too low → requests **queue** at PHP-FPM; NGINX may return **502/504** under load.

### Suggested starting pool for this lab

Create `app/php-fpm/www.conf` (or mount via ConfigMap) — starting point only:

```ini
[www]
user = www-data
group = www-data
listen = 9000

pm = dynamic
pm.max_children = 10
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 4
pm.max_requests = 500

; Fail fast instead of hanging forever
request_terminate_timeout = 30s
```

Rebuild the image or mount this file in the Deployment before applying pool settings.

### PHP `memory_limit`

Set in `php.ini` or pool config:

```ini
memory_limit = 128M
```

`memory_limit` is **per request**, not per pod.  
Worst case RAM ≈ `pm.max_children × memory_limit` (if every worker hits the limit).  
For safety: `pm.max_children × memory_limit` should be **less than** the pod memory **limit**.

Example: `10 × 128M = 1280M` → pod limit should be **≥ 1536Mi** or lower `max_children`.

---

## 4. Kubernetes resources (PHP-FPM Deployment)

Add requests/limits so the scheduler and kubelet can enforce fairness:

```yaml
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m      # 0.5 of 2 cores — leaves room for NGINX + promstack
    memory: 512Mi  # tune using §3 formula
```

### CPU

- **requests**: guaranteed minimum; used for scheduling.
- **limits**: cap; throttling happens when exceeded (can slow PHP under burst load).

On a **2-core worker**, avoid summing all pod CPU limits to much more than **2000m** without understanding burst overlap.  
Typical split for this lab:

| Workload | CPU limit (starting point) |
|---|---|
| php-fpm | 500m |
| nginx (+ sidecar) | 200m |
| nginx-exporter | 100m |
| promstack (already set) | ~1800m combined |

If everything limits at once, the node **throttles** — latency rises before OOM.

### Memory

- Always set **memory limits** on PHP-FPM in production/lab.
- Without limits, one PHP spike can evict other pods.

### Horizontal scaling

When one pod is not enough:

```bash
kubectl scale deployment php-fpm -n php-nginx-demo --replicas=3
```

Rules:

- Each replica uses its **own** `pm.max_children` pool.
- Total concurrency ≈ `replicas × pm.max_children`.
- Ensure the **node** has RAM/CPU for all replicas + promstack.
- NGINX `fastcgi_pass php-fpm:9000` already load-balances across Service endpoints.

Scale **replicas** when single-pod CPU is saturated; tune **pm.max_children** when memory-bound or queueing inside one pod.

---

## 5. NGINX tuning

Config lives in `k8s/03-nginx-configmap.yaml`.

### Workers and connections

NGINX uses event workers (usually 1 per CPU in containers):

```nginx
worker_processes auto;
events {
    worker_connections 1024;
}
```

Max rough connections ≈ `worker_processes × worker_connections`.  
For this demo, defaults are sufficient. Raise `worker_connections` only when `worker_connections are not enough` appears in error logs.

### FastCGI timeouts (important under load)

When PHP is slow or scaled to zero, NGINX waits for upstream:

```nginx
location ~ \.php$ {
    fastcgi_connect_timeout 5s;
    fastcgi_send_timeout    60s;
    fastcgi_read_timeout    60s;
    # ... existing fastcgi_pass ...
}
```

- **`fastcgi_connect_timeout`**: how long to wait for PHP-FPM to accept (502 if PHP pod is down).
- **`fastcgi_read_timeout`**: how long to wait for PHP to finish.

Shorter connect timeout → fail faster when PHP is at 0 replicas (good for demos/alerts).

### Keepalive to PHP-FPM (optional optimization)

By default each request may open a new FastCGI connection. For high QPS, use upstream keepalive (more config). Skip for this lab unless load testing shows connection overhead.

---

## 6. Other workloads on the cluster (promstack, etc.)

Tuning PHP is not isolated — **everything on the worker competes**.

### kube-prometheus-stack (Observability values)

Reduced scrape interval (30s) and tight resource limits suit small nodes.

| Component | Impact on tuning |
|---|---|
| **Prometheus** | RAM spikes during compaction; keep retention/size limits |
| **Grafana** | Largest consumer; avoid heavy dashboards on tiny nodes |
| **node-exporter** | DaemonSet on every node; small but permanent |
| **kube-state-metrics** | Low cost |

**Before raising PHP limits**, check:

```bash
kubectl top pods -A --sort-by=memory | head -20
```

If Prometheus + Grafana use ~2 GiB at idle, PHP pod limit of **512 Mi–1 Gi** is realistic, not 3 Gi.

### System pods

`kube-proxy`, CNI (Calico/Flannel), CoreDNS — usually a few hundred MiB total. Include them in mental budget.

### Noisy neighbors

When adding Redis, MySQL, or CI runners on the same worker, subtract their limits from the PHP budget or move workloads to another node.

---

## 7. Load testing

Validate tuning with simple tools:

```bash
# Install hey or use ab
hey -z 30s -c 20 http://<worker-ip>/

# Watch during test
kubectl top pod -n php-nginx-demo
kubectl get hpa -n php-nginx-demo   # when HPA is configured
```

Watch for:

| Symptom | Likely cause | Knob |
|---|---|---|
| 502 Bad Gateway | PHP pod down or `fastcgi_connect` failed | replicas, health checks |
| 504 Gateway Timeout | PHP too slow | `request_terminate_timeout`, app code, CPU |
| OOMKilled on php-fpm | `pm.max_children` or `memory_limit` too high | lower max_children or raise pod limit |
| High latency, low CPU | too few PHP workers | raise `pm.max_children` or replicas |
| Node NotReady / evictions | total RAM exceeded | lower limits cluster-wide |

After scaling PHP to 0 (failure test):

```bash
curl -i http://<worker-ip>/   # expect 502
```

Check metrics:

```promql
sum(rate(nginx_http_response_count_total{status=~"5.."}[5m]))
```

---

## 8. Worked example — this lab cluster

**Assumptions:** 2 CPU, 5 GiB worker, promstack installed, 1 nginx + 1 php-fpm replica.

### Step A — Set PHP Deployment resources

```yaml
# k8s/01-php-fpm-deployment.yaml (add under container)
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 512Mi
```

### Step B — PHP-FPM pool (inside image or ConfigMap)

```ini
pm = dynamic
pm.max_children = 10
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 4
pm.max_requests = 500
```

With ~40 MiB/worker → ~400 MiB peak + overhead ≈ fits 512 MiB limit.

### Step C — NGINX

Add `fastcgi_connect_timeout 5s` for faster 502 when PHP is unavailable.

### Step D — Verify

```bash
hey -z 20s -c 10 http://<worker-ip>/
kubectl top pod -n php-nginx-demo
```

If memory stays under ~400 MiB and no 502s → OK.  
If PHP hits 512 MiB limit → lower `pm.max_children` to 8.

### Step E — Scaling beyond one worker

1. Add a second worker node (best).
2. Or reduce promstack footprint (shorter retention, disable Grafana when not needed).
3. Or scale `php-fpm` replicas **only if** node has free CPU/RAM after `kubectl top node`.

---

## 9. Tuning on other cluster sizes

Use the same formulas; change the numbers.

| Cluster profile | PHP starting point |
|---|---|
| **1 worker, 2 CPU, 4–8 GiB** (this lab) | 1 replica, 512Mi limit, max_children 8–12 |
| **2 workers, 4 CPU, 16 GiB** | 2–4 replicas, 512Mi–1Gi each, max_children 15–20 |
| **Managed cloud (EKS/GKE), autoscaling nodes** | Set requests low, limits per app SLO; use HPA on CPU or custom metrics |
| **Production multi-tier** | PHP on app nodes, DB on separate pool; avoid co-locating with Prometheus |

### HPA (optional next step)

When CPU > 70% sustained:

```yaml
# HorizontalPodAutoscaler targeting php-fpm Deployment
minReplicas: 1
maxReplicas: 4
targetCPUUtilizationPercentage: 70
```

HPA only helps if the **node** has capacity to schedule new pods.

---

## 10. Checklist before a demo or load test

- [ ] `kubectl top node` — worker not already at 90%+ memory
- [ ] PHP pod has memory **requests** and **limits**
- [ ] `pm.max_children` calculated from measured RSS, not guessed
- [ ] NGINX `fastcgi_*_timeout` set
- [ ] Prometheus scraping `nginx_http_response_count_total` (5xx visible)
- [ ] Scale command: `kubectl scale deployment php-fpm --replicas=N`

---

## Related files

| File | Purpose |
|---|---|
| `app/php-fpm/index.php` | Application (client IP JSON) |
| `k8s/01-php-fpm-deployment.yaml` | PHP-FPM pod — add resources here |
| `k8s/03-nginx-configmap.yaml` | NGINX FastCGI + timeouts |
| `app/php-fpm/Dockerfile` | Extend to COPY custom `www.conf` / `php.ini` |
| `steps/README.md` | Build, deploy, monitoring and 5xx verification |

When pool config is baked into the image, document the rebuild step in `steps/README.md` (Step 2).
