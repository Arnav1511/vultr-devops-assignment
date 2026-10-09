#!/usr/bin/env bash
# Installs metrics-server and the Prometheus/Grafana stack. Safe to re-run.
set -euo pipefail
cd "$(dirname "$0")"

./install-metrics-server.sh

kubectl apply -f namespace.yaml

# Generate the Grafana admin password once and keep it only in the cluster.
# Read it back with:
#   kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d
if ! kubectl -n monitoring get secret grafana-admin >/dev/null 2>&1; then
  kubectl -n monitoring create secret generic grafana-admin \
    --from-literal=admin-user=admin \
    --from-literal=admin-password="$(openssl rand -base64 24)"
fi

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
# If alert e-mail has been set up (alertmanager-email.sh), keep using its
# configuration; otherwise a re-run would silently switch e-mail off.
EMAIL_VALUES=()
if kubectl -n monitoring get secret alertmanager-email-config >/dev/null 2>&1; then
  EMAIL_VALUES=(-f alertmanager-email-values.yaml)
fi

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n monitoring --version 92.2.0 -f kube-prometheus-stack-values.yaml "${EMAIL_VALUES[@]}" \
  --wait --timeout 10m

kubectl apply -f grafana-httproute.yaml

# Custom alert rules, mesh metrics and the two custom dashboards.
kubectl apply -f alerts.yaml
kubectl apply -f ztunnel-podmonitor.yaml
kubectl apply -k dashboards
