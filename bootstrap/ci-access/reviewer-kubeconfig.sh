#!/usr/bin/env bash
# Prints a read-only kubeconfig for a reviewer, valid for 7 days.
#
#   ./reviewer-kubeconfig.sh > reviewer.kubeconfig
#
# It is bound to Kubernetes' built-in "view" ClusterRole, which can read
# workloads, services, config and events in every namespace but cannot read
# Secrets and cannot change anything. The token expires on its own, so access
# does not need to be remembered and revoked.
set -euo pipefail

kubectl create namespace reviewers --dry-run=client -o yaml | kubectl apply -f - >&2
kubectl -n reviewers create serviceaccount reviewer --dry-run=client -o yaml | kubectl apply -f - >&2
kubectl create clusterrolebinding reviewer-view --clusterrole=view \
  --serviceaccount=reviewers:reviewer --dry-run=client -o yaml | kubectl apply -f - >&2

SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
CA=$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
TOKEN=$(kubectl -n reviewers create token reviewer --duration=168h)

cat <<KUBECONFIG
apiVersion: v1
kind: Config
clusters:
  - name: vke
    cluster:
      server: ${SERVER}
      certificate-authority-data: ${CA}
users:
  - name: reviewer
    user:
      token: ${TOKEN}
contexts:
  - name: vke
    context:
      cluster: vke
      user: reviewer
current-context: vke
KUBECONFIG
