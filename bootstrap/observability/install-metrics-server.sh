#!/usr/bin/env bash
# VKE does not ship metrics-server. Without it the metrics.k8s.io API does not
# exist, every HPA reports "cpu: <unknown>" and never scales, and
# `kubectl top` fails. Chart defaults work on VKE: kubelet serving certificates
# verify, so --kubelet-insecure-tls is not needed.
set -euo pipefail
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ --force-update
helm upgrade --install metrics-server metrics-server/metrics-server \
  -n kube-system --version 3.14.0 --wait
