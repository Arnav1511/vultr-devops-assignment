#!/usr/bin/env bash
# Installs Vault and the Vault Secrets Operator, initialises and unseals Vault,
# and configures it for the app. Safe to re-run.
set -euo pipefail
cd "$(dirname "$0")"

INIT_FILE=.vault-init.json   # git-ignored: holds the unseal key and root token
v() { kubectl -n vault exec -i vault-0 -- env VAULT_TOKEN="${VAULT_TOKEN:-}" vault "$@"; }

kubectl apply -f namespace.yaml
helm repo add hashicorp https://helm.releases.hashicorp.com --force-update
# No --wait: a sealed Vault never becomes Ready, so the wait would time out.
helm upgrade --install vault hashicorp/vault -n vault --version 0.34.1 -f vault-values.yaml
kubectl -n vault wait --for=jsonpath='{.status.phase}'=Running pod/vault-0 --timeout=180s

# Initialise once. One key share is a deliberate simplification: production
# would split the key (e.g. 5 shares, any 3 unseal) across different people.
if ! v status -format=json 2>/dev/null | grep -q '"initialized": true'; then
  v operator init -key-shares=1 -key-threshold=1 -format=json > "$INIT_FILE"
  chmod 600 "$INIT_FILE"
fi
./unseal.sh

VAULT_TOKEN=$(python3 -c "import json;print(json.load(open('$INIT_FILE'))['root_token'])")

# KV v2 secrets engine: versioned key/value storage.
v secrets list -format=json | grep -q '"secret/"' || v secrets enable -path=secret kv-v2

# Kubernetes auth: Vault validates service-account tokens against the API server.
v auth list -format=json | grep -q '"kubernetes/"' || v auth enable kubernetes
v write auth/kubernetes/config kubernetes_host=https://kubernetes.default.svc >/dev/null
v policy write app-read - < policy.hcl >/dev/null
v write auth/kubernetes/role/vso \
  bound_service_account_names=vso-auth \
  bound_service_account_namespaces=app-dev,app-staging,app-prod,databases \
  audience=vault token_policies=app-read token_ttl=1h >/dev/null

# Seed the database passwords once. If the databases are already running,
# reuse their current passwords (changing them here would not change them
# inside the databases); otherwise generate new ones. Values travel on stdin,
# never on a command line.
if ! v kv get secret/app/databases >/dev/null 2>&1; then
  if kubectl -n databases get secret db-credentials >/dev/null 2>&1; then
    kubectl -n databases get secret db-credentials -o json \
      | python3 -c "import sys,json,base64;print(json.dumps({k:base64.b64decode(x).decode() for k,x in json.load(sys.stdin)['data'].items()}))"
  else
    python3 -c "import json,secrets;print(json.dumps({k+'-password':secrets.token_hex(24) for k in ('postgres','mongodb','valkey')}))"
  fi | v kv put secret/app/databases - >/dev/null
fi

# Seed the registry pull credentials from the Terraform outputs, in the
# .dockerconfigjson format Kubernetes expects for an imagePullSecret.
# Needs the Terraform backend credentials in the environment.
if ! v kv get secret/app/registry >/dev/null 2>&1; then
  ( cd ../../terraform
    REG_HOST=$(terraform output -raw registry_urn | cut -d/ -f1) \
    REG_USER=$(terraform output -raw registry_username) \
    REG_PASS=$(terraform output -raw registry_password) \
    python3 -c "
import os, json, base64
auth = base64.b64encode((os.environ['REG_USER'] + ':' + os.environ['REG_PASS']).encode()).decode()
cfg = {'auths': {os.environ['REG_HOST']: {'auth': auth}}}
print(json.dumps({'.dockerconfigjson': json.dumps(cfg)}))" ) | v kv put secret/app/registry - >/dev/null
fi

helm upgrade --install vault-secrets-operator hashicorp/vault-secrets-operator \
  -n vault --version 1.6.0 -f vso-values.yaml --wait

if kubectl get namespace databases >/dev/null 2>&1; then
  kubectl apply -f databases-secret.yaml
fi
