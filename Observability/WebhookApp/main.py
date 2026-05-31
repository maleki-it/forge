#!/usr/bin/env python3
"""
Alertmanager webhook → Telegram notifier.

Config via environment (mount from Kubernetes ConfigMap):
  TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID, MESSAGE_TEMPLATE, WEBHOOK_PATH, LISTEN_PORT
"""

from __future__ import annotations

import html
import json
import logging
import os
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger("alert-webhook")

DEFAULT_TEMPLATE = """\
<b>{status_emoji} {status}</b> — {receiver}
<b>Alert:</b> {alertname}
<b>Severity:</b> {severity}
<b>Summary:</b> {summary}
<b>Description:</b> {description}
<b>Alerts in group:</b> {alert_count}
"""

STATUS_EMOJI = {
    "firing": "🔥",
    "resolved": "✅",
}


def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default).strip()


def render_template(template: str, payload: dict, alert: dict, escape_html: bool) -> str:
    labels = alert.get("labels") or {}
    annotations = alert.get("annotations") or {}
    status = (alert.get("status") or payload.get("status") or "unknown").lower()
    alerts = payload.get("alerts") or []

    def val(key: str, default: str = "") -> str:
        text = str(default)
        return html.escape(text, quote=False) if escape_html else text

    values = {
        "status": val("status", status),
        "status_emoji": STATUS_EMOJI.get(status, "⚠️"),
        "receiver": val("receiver", payload.get("receiver", "unknown")),
        "alertname": val("alertname", labels.get("alertname", "unknown")),
        "severity": val("severity", labels.get("severity", "none")),
        "namespace": val("namespace", labels.get("namespace", "")),
        "service": val("service", labels.get("service", "")),
        "summary": val("summary", annotations.get("summary", "-")),
        "description": val("description", annotations.get("description", "-")),
        "alert_count": str(len(alerts)),
        "group_key": val("group_key", payload.get("groupKey", "")),
        "starts_at": val("starts_at", alert.get("startsAt", "")),
        "ends_at": val("ends_at", alert.get("endsAt", "")),
        "generator_url": val("generator_url", alert.get("generatorURL", "")),
    }

    try:
        return template.format(**values)
    except KeyError as exc:
        log.warning("template placeholder missing: %s", exc)
        return (
            f"{values['status_emoji']} {values['alertname']}: "
            f"{values['summary']}\n{values['description']}"
        )


def send_telegram(token: str, chat_id: str, text: str, parse_mode: str) -> None:
    url = f"https://api.telegram.org/bot{token}/sendMessage"
    fields = {
        "chat_id": chat_id,
        "text": text[:4096],
        "disable_web_page_preview": "true",
    }
    if parse_mode:
        fields["parse_mode"] = parse_mode
    body = urllib.parse.urlencode(fields).encode("utf-8")
    req = urllib.request.Request(url, data=body, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            result = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        try:
            tg = json.loads(detail)
            desc = tg.get("description", detail)
        except json.JSONDecodeError:
            desc = detail
        raise RuntimeError(f"Telegram HTTP {exc.code}: {desc}") from exc
    if not result.get("ok"):
        raise RuntimeError(f"Telegram API error: {result}")


class WebhookHandler(BaseHTTPRequestHandler):
    template = DEFAULT_TEMPLATE
    webhook_path = "/webhook"
    bot_token = ""
    chat_id = ""
    parse_mode = "HTML"

    def log_message(self, fmt: str, *args) -> None:
        log.info("%s - %s", self.address_string(), fmt % args)

    def _reply(self, code: int, body: dict) -> None:
        data = json.dumps(body).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self) -> None:
        if self.path in ("/", "/health", "/healthz"):
            self._reply(200, {"status": "ok"})
            return
        self._reply(404, {"error": "not found"})

    def do_POST(self) -> None:
        if self.path != self.webhook_path:
            self._reply(404, {"error": "not found"})
            return

        if not self.bot_token or not self.chat_id:
            log.error("TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID not set")
            self._reply(500, {"error": "telegram not configured"})
            return

        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length)
        try:
            payload = json.loads(raw.decode("utf-8"))
        except json.JSONDecodeError:
            self._reply(400, {"error": "invalid json"})
            return

        alerts = payload.get("alerts") or []
        if not alerts:
            log.info("empty alert group, skipping telegram")
            self._reply(200, {"sent": 0})
            return

        sent = 0
        errors: list[str] = []
        for alert in alerts:
            text = render_template(
                self.template,
                payload,
                alert,
                escape_html=self.parse_mode.upper() == "HTML",
            )
            try:
                send_telegram(self.bot_token, self.chat_id, text, self.parse_mode)
                sent += 1
                log.info(
                    "telegram sent alert=%s status=%s",
                    (alert.get("labels") or {}).get("alertname"),
                    alert.get("status"),
                )
            except (urllib.error.URLError, RuntimeError, TimeoutError) as exc:
                msg = str(exc)
                log.error("telegram send failed: %s", msg)
                errors.append(msg)

        if errors and sent == 0:
            self._reply(502, {"sent": 0, "errors": errors})
            return

        self._reply(200, {"sent": sent, "errors": errors})


def main() -> None:
    port = int(env("LISTEN_PORT", "8080"))
    WebhookHandler.webhook_path = env("WEBHOOK_PATH", "/webhook")
    WebhookHandler.bot_token = env("TELEGRAM_BOT_TOKEN")
    WebhookHandler.chat_id = env("TELEGRAM_CHAT_ID")
    WebhookHandler.template = env("MESSAGE_TEMPLATE") or DEFAULT_TEMPLATE
    WebhookHandler.parse_mode = env("TELEGRAM_PARSE_MODE", "HTML")

    server = ThreadingHTTPServer(("0.0.0.0", port), WebhookHandler)
    log.info(
        "listening on :%s path=%s chat_id=%s",
        port,
        WebhookHandler.webhook_path,
        WebhookHandler.chat_id or "(not set)",
    )
    server.serve_forever()


if __name__ == "__main__":
    main()
