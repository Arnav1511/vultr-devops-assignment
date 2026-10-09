#!/usr/bin/env bash
# Installs Gateway API CRDs and Istio in ambient mode. Safe to re-run.
set -euo pipefail
cd "$(dirname "$0")"

ISTIO_VERSION=1.30.5
# The Gateway API version Istio 1.30 is tested against (istio.io release-1.30).
GATEWAY_API_VERSION=v1.5.1

# Gateway API CRDs are not shipped with VKE or with the Istio charts. They must
# exist before istiod starts, or istiod will not watch Gateway/HTTPRoute.
kubectl apply --server-side -f \
  "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

helm repo add istio https://istio-release.storage.googleapis.com/charts --force-update
helm repo update istio

# Order matters: CRDs (base) -> control plane -> CNI agent -> ztunnel.
helm upgrade --install istio-base istio/base -n istio-system --create-namespace \
  --version "$ISTIO_VERSION" --wait
helm upgrade --install istiod istio/istiod -n istio-system \
  --version "$ISTIO_VERSION" -f istiod-values.yaml --wait
helm upgrade --install istio-cni istio/cni -n istio-system \
  --version "$ISTIO_VERSION" -f cni-values.yaml --wait
helm upgrade --install ztunnel istio/ztunnel -n istio-system \
  --version "$ISTIO_VERSION" -f ztunnel-values.yaml --wait

kubectl apply -f peer-authentication.yaml
