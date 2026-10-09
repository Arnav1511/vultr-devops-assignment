#!/usr/bin/env bash
# Unseals Vault with the key saved at init time. Needed after every restart of
# the vault-0 pod: Vault starts sealed, with its data encrypted and unreadable,
# until the key is supplied. While it is sealed, already-synced Kubernetes
# Secrets keep working; only new syncs and rotations stop.
set -euo pipefail
cd "$(dirname "$0")"
if kubectl -n vault exec vault-0 -- vault status -format=json 2>/dev/null | grep -q '"sealed": false'; then
  echo "vault is already unsealed"; exit 0
fi
python3 -c "import json;print(json.load(open('.vault-init.json'))['unseal_keys_b64'][0])" \
  | kubectl -n vault exec -i vault-0 -- sh -c 'vault operator unseal "$(cat)"' >/dev/null
echo "vault unsealed"
