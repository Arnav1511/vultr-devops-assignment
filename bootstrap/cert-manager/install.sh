#!/usr/bin/env bash
# Installs cert-manager and the Let's Encrypt issuer. Safe to re-run.
# The cert-manager namespace is deliberately NOT in the ambient mesh: its
# admission webhook is called by the API server, which is outside the mesh and
# would be rejected by STRICT mTLS.
set -euo pipefail
cd "$(dirname "$0")"
helm upgrade --install cert-manager oci://quay.io/jetstack/charts/cert-manager \
  -n cert-manager --create-namespace --version v1.21.2 -f values.yaml --wait
kubectl apply -f cluster-issuer.yaml
