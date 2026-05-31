# Alertmanager → Telegram webhook

Minimal Python service: receives Alertmanager webhook POSTs and sends messages to a Telegram channel.

Config (token, chat ID, message template) lives in a **ConfigMap** — edit and restart the pod; no image rebuild.

## Layout

```
WebhookApp/
├── main.py
├── Dockerfile
├── k8s/
│   ├── 01-configmap.yaml
│   ├── 02-deployment.yaml
│   └── 03-service.yaml
└── README.md
```

## Configure Telegram

1. Create a bot via [@BotFather](https://t.me/BotFather) → copy **bot token**.
2. Add the bot to the target channel (as admin for channels).
3. Get **chat ID**:
   - Private chat: message the bot, open  
     `https://api.telegram.org/bot<TOKEN>/getUpdates`
   - Channel: usually `-100xxxxxxxxxx`

Edit `k8s/01-configmap.yaml`:

```yaml
TELEGRAM_BOT_TOKEN: "123456:ABC..."
TELEGRAM_CHAT_ID: "-1001234567890"
```

Adjust `MESSAGE_TEMPLATE` if needed (HTML supported when `TELEGRAM_PARSE_MODE=HTML`).

**Chat ID checklist**

| Target | What to do |
|--------|------------|
| **Private chat** | Open the bot in Telegram and send `/start` first |
| **Group** | Add bot to group; chat ID is negative (use `getUpdates`) |
| **Channel** | Bot must be channel admin; chat ID like `-100xxxxxxxxxx` |

Verify token + chat ID:

```bash
curl -s "https://api.telegram.org/bot<TOKEN>/getMe"
curl -s "https://api.telegram.org/bot<TOKEN>/sendMessage" \
  -d chat_id=<CHAT_ID> -d text=test
```

If that `sendMessage` returns 400, fix chat ID or `/start` before testing the webhook.

## Build and deploy

```bash
cd Observability/WebhookApp

# multi-arch — build context must be exactly one "." at the end
docker buildx build --platform linux/amd64,linux/arm64 \
  -t alimi1/alert-telegram-webhook:latest \
  --push .

kubectl apply -f k8s/
kubectl rollout restart deployment/alert-telegram-webhook -n monitoring
```

After ConfigMap changes:

```bash
kubectl apply -f k8s/01-configmap.yaml
kubectl rollout restart deployment/alert-telegram-webhook -n monitoring
```

## Wire Alertmanager

Add a webhook receiver pointing at the in-cluster Service.

**Option A — patch Observability `values.yaml`** under `alertmanager.config`:

```yaml
alertmanager:
  config:
    route:
      receiver: telegram
      routes:
        - receiver: telegram
          matchers:
            - severity=~"warning|critical"
    receivers:
      - name: telegram
        webhook_configs:
          - url: http://alert-telegram-webhook.monitoring.svc.cluster.local:8080/webhook
            send_resolved: true
```

Then:

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update prometheus-community
helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n monitoring -f values.yaml --version 86.0.1 --wait
```

**Option B — test without Alertmanager**

```bash
kubectl port-forward -n monitoring svc/alert-telegram-webhook 8080:8080

curl -s -X POST http://127.0.0.1:8080/webhook \
  -H 'Content-Type: application/json' \
  -d '{
    "receiver": "telegram",
    "status": "firing",
    "alerts": [{
      "status": "firing",
      "labels": {"alertname": "TestAlert", "severity": "warning", "namespace": "php-nginx-demo"},
      "annotations": {"summary": "Test from curl", "description": "Webhook OK"}
    }]
  }'
```

## Endpoints

| Path | Method | Purpose |
|------|--------|---------|
| `/health` | GET | Kubernetes probes |
| `/webhook` | POST | Alertmanager payload |

## Security note

The bot token is stored in a ConfigMap for lab convenience. For production, move `TELEGRAM_BOT_TOKEN` to a Kubernetes **Secret** and reference it in the Deployment instead of `envFrom` on the ConfigMap.
