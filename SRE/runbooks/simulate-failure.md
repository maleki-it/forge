# Runbook — simulate failure

Controlled failure scenarios for the php-nginx-demo stack. Use with Prometheus, Alertmanager, and the [Grafana dashboard](../../Observability/dashboards/php-nginx-demo.json) open.

## Prerequisites

- [App](../../App/) deployed in `php-nginx-demo`
- [Observability](../../Observability/) installed in `monitoring`
- [Alert rules](../alerts/php-nginx-demo-rules.yaml) applied
- Worker IP or CDN domain reachable for `curl`

---

## Scenario A — PHP-FPM unavailable (recommended)

**Simulates:** upstream down → NGINX **502 Bad Gateway**  
**Maps to:** production PHP-FPM crash, OOMKill, or scaled-to-zero during bad deploy

### Inject

```bash
kubectl scale deployment php-fpm -n php-nginx-demo --replicas=0
kubectl get pods -n php-nginx-demo -l app=php-fpm   # no running pods
curl -i http://<worker-ip>/
```

Expected response: `HTTP/1.1 502 Bad Gateway`

### Observe

| Check | Command / location |
|-------|-------------------|
| Access-log 502 counter | `curl -s http://127.0.0.1:4040/metrics \| grep 'status="502"'` (port-forward `svc/nginx-log-metrics`) |
| Grafana | 5XX rate panel spikes |
| Prometheus alerts | `NginxHigh5xxRate`, `PhpFpmDeploymentNotReady` → firing after `for:` window |
| Alertmanager | http://localhost:9093 (port-forward `svc/kube-prometheus-stack-alertmanager`) |

Generate load to make graphs move:

```bash
hey -z 30s -c 5 http://<worker-ip>/
```

### Recover

```bash
kubectl scale deployment php-fpm -n php-nginx-demo --replicas=1
kubectl rollout status deployment/php-fpm -n php-nginx-demo
curl -i http://<worker-ip>/    # expect 200 + JSON
```

Alerts should return to **inactive** within a few minutes.

### Postmortem

Record timeline and learnings in [../postmortems/2026-05-31-php-fpm-unavailable.md](../postmortems/2026-05-31-php-fpm-unavailable.md) (copy and edit dates as needed).

---

## Scenario B — Kill NGINX pod (resilience)

**Simulates:** pod crash → Kubernetes restart  
**Maps to:** node drain, OOMKill, or accidental `kubectl delete pod`

### Inject

```bash
kubectl delete pod -n php-nginx-demo -l app=nginx
```

Deployment recreates the pod. Expect **brief** connection errors, not sustained 502 (PHP-FPM still running).

### Observe

- `nginx_connections_*` dip on Grafana
- `nginx_up` may flicker
- 502 rate should stay low unless PHP-FPM is also unhealthy

---

## Scenario C — Log format mismatch (monitoring failure)

**Simulates:** config drift → exporter parse errors, missing metrics  
**Maps to:** NGINX log format changed without updating log-exporter config

Already documented in [App/k8s/03-nginx-configmap.yaml](../../App/k8s/03-nginx-configmap.yaml) — `nginx_parse_errors_total` rises while the app still serves traffic.

**Do not run in production.** For lab replay, temporarily revert `log_format` without matching exporter config, then fix and restart.

Alert: `NginxLogParseErrors`

---

## Scenario comparison

| Scenario | Client impact | Primary metric | Primary alert |
|----------|---------------|----------------|---------------|
| A — PHP-FPM scale to 0 | Sustained 502 | `nginx_http_response_count_total{status="502"}` | `NginxHigh5xxRate` |
| B — delete NGINX pod | Brief errors | `nginx_up`, connections | optional flicker |
| C — log format drift | None (app OK) | `nginx_parse_errors_total` | `NginxLogParseErrors` |
