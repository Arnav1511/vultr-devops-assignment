#!/usr/bin/env bash
# Installs Argo CD, gives it read-only access to the private repository and
# creates the three Applications. Safe to re-run. Needs the `gh` CLI logged in.
set -euo pipefail
cd "$(dirname "$0")"
REPO=Arnav1511/vultr-devops-assignment

helm repo add argo https://argoproj.github.io/argo-helm --force-update
helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace \
  --version 10.10.2 -f values.yaml --wait --timeout 10m

# Repository access: a dedicated SSH deploy key that can read this one repo
# and nothing else. Rejected alternative: a personal access token, which would
# grant access to every repository the account can see. The private key goes
# straight into a cluster Secret and is never written to the working tree.
if ! kubectl -n argocd get secret repo-vultr-devops-assignment >/dev/null 2>&1; then
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  ssh-keygen -q -t ed25519 -N "" -C argocd-deploy-key -f "$tmp/key"
  gh repo deploy-key add "$tmp/key.pub" --repo "$REPO" --title argocd-read-only
  kubectl -n argocd create secret generic repo-vultr-devops-assignment \
    --from-literal=type=git \
    --from-literal=url="git@github.com:${REPO}.git" \
    --from-file=sshPrivateKey="$tmp/key"
  # This label is how Argo CD recognises a Secret as repository credentials.
  kubectl -n argocd label secret repo-vultr-devops-assignment \
    argocd.argoproj.io/secret-type=repository
fi

kubectl apply -f applications.yaml
