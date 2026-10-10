#!/usr/bin/env bash
# Installs PostgreSQL, MongoDB and Valkey from the local single-db chart.
# Requires the observability stack first (the chart creates ServiceMonitors).
# Safe to re-run.
#
# Why a small local chart instead of community charts: Bitnami's free images
# were retired in 2025, and the operator-based alternatives (CloudNativePG,
# Percona) add admission webhooks that the API server cannot reach under
# STRICT mTLS without extra exceptions. One ~150-line chart is something every
# line of which can be explained. Operators are the production answer and are
# listed under suggested advancements.
set -euo pipefail
cd "$(dirname "$0")"

kubectl apply -f namespace.yaml

# Bootstrap passwords: generated once, stored only in the cluster. Replaced by
# operator-synced secrets once the secrets manager is in place. Hex, so the
# value is safe inside a connection URI without escaping.
if ! kubectl -n databases get secret db-credentials >/dev/null 2>&1; then
  kubectl -n databases create secret generic db-credentials \
    --from-literal=postgres-admin-password="$(openssl rand -hex 24)" \
    --from-literal=postgres-app-password="$(openssl rand -hex 24)" \
    --from-literal=mongodb-admin-password="$(openssl rand -hex 24)" \
    --from-literal=mongodb-app-password="$(openssl rand -hex 24)" \
    --from-literal=valkey-password="$(openssl rand -hex 24)"
fi

for db in postgres mongodb valkey; do
  helm upgrade --install "$db" ./chart -n databases -f "${db}-values.yaml" \
    --wait --timeout 5m
done

# Non-admin "app" accounts for the backend (see the script for the reasoning).
./create-app-users.sh

# Restrict database access to the backend, Prometheus and the backup job.
kubectl apply -f authorization-policy.yaml

# Nightly backups. The job's object storage keys are synced from Vault by
# bootstrap/secrets/install.sh, so the first run succeeds only after that.
kubectl apply -f backup-cronjob.yaml
