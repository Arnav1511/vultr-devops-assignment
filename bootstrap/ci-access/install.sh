#!/usr/bin/env bash
# Creates the CI service account and stores its kubeconfig and the registry
# credentials as GitHub Actions secrets. Safe to re-run. Needs `gh` logged in
# and the Terraform backend credentials in the environment.
set -euo pipefail
cd "$(dirname "$0")"
REPO=Arnav1511/vultr-devops-assignment

kubectl apply -f rbac.yaml

# Wait for Kubernetes to populate the token.
until kubectl -n ci get secret github-deployer-token -o jsonpath='{.data.token}' | grep -q .; do sleep 1; done

SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
CA=$(kubectl -n ci get secret github-deployer-token -o jsonpath='{.data.ca\.crt}')
TOKEN=$(kubectl -n ci get secret github-deployer-token -o jsonpath='{.data.token}' | base64 -d)

# Secrets are piped to gh on stdin so they never appear in a process list.
cat <<KUBECONFIG | gh secret set KUBECONFIG --repo "$REPO"
apiVersion: v1
kind: Config
clusters:
  - name: vke
    cluster:
      server: ${SERVER}
      certificate-authority-data: ${CA}
users:
  - name: github-deployer
    user:
      token: ${TOKEN}
contexts:
  - name: vke
    context:
      cluster: vke
      user: github-deployer
current-context: vke
KUBECONFIG

( cd ../../terraform
  terraform output -raw registry_username | gh secret set REGISTRY_USERNAME --repo "$REPO"
  terraform output -raw registry_password | gh secret set REGISTRY_PASSWORD --repo "$REPO" )
