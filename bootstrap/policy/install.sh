#!/usr/bin/env bash
# Installs the admission webhook. Needs cert-manager (it issues the webhook's
# serving certificate and injects the CA into the webhook configuration).
# Safe to re-run.
#
# The namespace is NOT in the ambient mesh: the API server, which calls the
# webhook, is outside the mesh and would be rejected by STRICT mTLS.
set -euo pipefail
cd "$(dirname "$0")"

# The chart is not published to a registry, so it is taken from the project's
# repository at a pinned commit.
CHART_COMMIT=2d32de32c71edd0dc45aca3b1fe529760fed6643
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
git clone --quiet https://github.com/Arnav1511/Kubernetes-admission-webhook.git "$tmp/src"
git -C "$tmp/src" checkout --quiet "$CHART_COMMIT"

helm upgrade --install k8s-policy-webhook "$tmp/src/deploy/helm" \
  -n policy-system --create-namespace -f values.yaml --wait --timeout 5m
