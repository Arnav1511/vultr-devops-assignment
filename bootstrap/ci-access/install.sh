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

# A write deploy key used only for the deploy workflow's image-tag commits.
# It is the single identity allowed to bypass the branch ruleset on main.
if ! gh repo deploy-key list --repo "$REPO" | grep -q ci-deploy-commits; then
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  ssh-keygen -q -t ed25519 -N "" -C ci-deploy-commits -f "$tmp/key"
  gh repo deploy-key add "$tmp/key.pub" --repo "$REPO" --title ci-deploy-commits --allow-write
  gh secret set DEPLOY_KEY --repo "$REPO" < "$tmp/key"
fi

# Branch ruleset: pull request + passing checks required on main.
RULESET=../../.github/rulesets/protect-main.json
ID=$(gh api "repos/$REPO/rulesets" --jq '.[] | select(.name=="protect-main") | .id')
if [[ -n "$ID" ]]; then
  gh api -X PUT "repos/$REPO/rulesets/$ID" --input "$RULESET" >/dev/null
else
  gh api -X POST "repos/$REPO/rulesets" --input "$RULESET" >/dev/null
fi

# Human approval before production: the prod environment requires a review
# from the repository owner, and only main may deploy to it.
OWNER_ID=$(gh api user --jq .id)
gh api -X PUT "repos/$REPO/environments/prod" --input - >/dev/null <<JSON
{"reviewers":[{"type":"User","id":${OWNER_ID}}],
 "deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}
JSON
gh api "repos/$REPO/environments/prod/deployment-branch-policies" --jq '.branch_policies[].name' | grep -qx main ||
  gh api -X POST "repos/$REPO/environments/prod/deployment-branch-policies" -f name=main -f type=branch >/dev/null
