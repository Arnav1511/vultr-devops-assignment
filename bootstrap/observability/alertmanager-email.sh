#!/usr/bin/env bash
# Sends Prometheus alerts by e-mail. Safe to re-run (e.g. to change recipient).
#
# Reads from the environment (put these in the git-ignored .env):
#   SMTP_USERNAME   account that logs in to the mail server
#   SMTP_PASSWORD   its password — for Gmail, an "app password", not the
#                   account password
#   ALERT_EMAIL_TO  where alerts are delivered
#   SMTP_HOST       optional, default smtp.gmail.com
#   SMTP_PORT       optional, default 587 (port 25 is blocked on Vultr)
#
# The sender shows as "Grafana Alerts (no-reply)". The address behind that
# name is SMTP_USERNAME: mail providers reject or rewrite a From address the
# logged-in account does not own.
set -euo pipefail
cd "$(dirname "$0")"

: "${SMTP_USERNAME:?set SMTP_USERNAME}" "${SMTP_PASSWORD:?set SMTP_PASSWORD}" "${ALERT_EMAIL_TO:?set ALERT_EMAIL_TO}"
SMTP_HOST=${SMTP_HOST:-smtp.gmail.com}
SMTP_PORT=${SMTP_PORT:-587}

kubectl -n monitoring create secret generic alertmanager-email-config \
  --dry-run=client -o yaml --from-file=alertmanager.yaml=/dev/stdin <<CONFIG | kubectl apply -f -
global:
  smtp_smarthost: "${SMTP_HOST}:${SMTP_PORT}"
  smtp_from: "Grafana Alerts (no-reply) <${SMTP_USERNAME}>"
  smtp_auth_username: "${SMTP_USERNAME}"
  smtp_auth_password: "${SMTP_PASSWORD}"
  smtp_require_tls: true

route:
  receiver: email
  # One e-mail per alert name and namespace, not one per pod.
  group_by: [alertname, namespace]
  # Wait 30s so alerts that fire together arrive as one message; re-send a
  # still-firing alert every 4h so it is not forgotten, without spamming.
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  routes:
    # Watchdog fires permanently by design (it proves the alert pipeline is
    # alive) and InfoInhibitor is internal plumbing; neither is actionable.
    - matchers: ['alertname =~ "Watchdog|InfoInhibitor"']
      receiver: "null"

# While a critical alert is firing, hold back warnings for the same alert in
# the same namespace: one message about the real problem, not two.
inhibit_rules:
  - source_matchers: ['severity = "critical"']
    target_matchers: ['severity = "warning"']
    equal: [alertname, namespace]

receivers:
  - name: "null"
  - name: email
    email_configs:
      - to: "${ALERT_EMAIL_TO}"
        # Also e-mail when the alert clears.
        send_resolved: true
CONFIG

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n monitoring --version 92.2.0 --wait --timeout 10m \
  -f kube-prometheus-stack-values.yaml -f alertmanager-email-values.yaml
