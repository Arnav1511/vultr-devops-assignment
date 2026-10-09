#!/usr/bin/env bash
# Deploys one image tag to one environment the GitOps way, verifies it, and
# rolls back automatically if verification fails.
#
#   deploy.sh <dev|staging|prod> <image-tag>
#
# "Deploy" means committing the new tag to the environment's Kustomize overlay.
# Argo CD applies it. This script never runs `kubectl apply`, and it rolls back
# with `git revert` rather than `kubectl rollout undo`, because Argo CD's
# self-heal would immediately put the broken version back.
set -euo pipefail

ENVIRONMENT=$1
TAG=$2
NS="app-${ENVIRONMENT}"
APP="app-${ENVIRONMENT}"
KUSTOMIZATION="k8s/overlays/${ENVIRONMENT}/kustomization.yaml"
PUBLIC_URL="https://app.139.84.159.60.sslip.io"
ROLLOUT_TIMEOUT=180s

current_tag() { grep -m1 'newTag:' "$KUSTOMIZATION" | tr -d ' "' | cut -d: -f2; }

# Wait until Argo CD has applied the wanted tag. Without the refresh
# annotation this could take up to Argo CD's 3-minute polling interval.
wait_for_sync() {
  local want=$1
  kubectl -n argocd annotate application "$APP" argocd.argoproj.io/refresh=normal --overwrite >/dev/null
  for _ in $(seq 1 36); do
    local image sync
    image=$(kubectl -n "$NS" get deployment backend -o jsonpath='{.spec.template.spec.containers[0].image}')
    sync=$(kubectl -n argocd get application "$APP" -o jsonpath='{.status.sync.status}')
    if [[ "$image" == *":${want}" && "$sync" == "Synced" ]]; then
      echo "Argo CD synced ${APP} to ${want}"
      return 0
    fi
    sleep 5
  done
  echo "::error::Argo CD did not sync ${APP} to ${want} within 3 minutes"
  return 1
}

# Rollout verification: blocks until every new pod is Ready, or fails on
# timeout (for example ImagePullBackOff or a failing readiness probe).
verify_rollout() {
  kubectl -n "$NS" rollout status deployment/backend --timeout="$ROLLOUT_TIMEOUT" &&
    kubectl -n "$NS" rollout status deployment/frontend --timeout="$ROLLOUT_TIMEOUT"
}

# Smoke tests: prove the new version actually serves requests, which a
# successful rollout alone does not. Run through a port-forward so dev and
# staging can be tested without being exposed publicly.
smoke_test() {
  local want=$1 pf_backend pf_frontend rc=0
  kubectl -n "$NS" port-forward svc/backend 18080:80 >/dev/null 2>&1 & pf_backend=$!
  kubectl -n "$NS" port-forward svc/frontend 18081:80 >/dev/null 2>&1 & pf_frontend=$!
  sleep 4

  check() { # description, command...
    local description=$1; shift
    if "$@" >/dev/null 2>&1; then echo "  PASS  $description"; else echo "  FAIL  $description"; rc=1; fi
  }
  check "backend /readyz reports every database reachable" \
    curl -fsS --max-time 10 localhost:18080/readyz
  check "backend reports version ${want}" \
    bash -c "curl -fsS --max-time 10 localhost:18080/api/status | grep -q '\"version\":\"${want}\"'"
  check "backend /api/messages reads from PostgreSQL" \
    curl -fsS --max-time 10 localhost:18080/api/messages
  check "frontend serves the UI" \
    bash -c "curl -fsS --max-time 10 localhost:18081/ | grep -q '<title>'"
  if [[ "$ENVIRONMENT" == "prod" ]]; then
    # Also through the real path: DNS, load balancer, TLS, Gateway, HTTPRoute.
    check "public URL serves the UI over HTTPS" \
      bash -c "curl -fsS --max-time 15 ${PUBLIC_URL}/ | grep -q '<title>'"
    check "public URL routes /api to the backend" \
      bash -c "curl -fsS --max-time 15 ${PUBLIC_URL}/api/status | grep -q '\"service\":\"backend\"'"
  fi

  kill "$pf_backend" "$pf_frontend" 2>/dev/null || true
  return $rc
}

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
# Another environment's job may have pushed since this job's checkout.
git pull --rebase --quiet origin main

PREVIOUS_TAG=$(current_tag)
DEPLOY_COMMIT=""
if [[ "$PREVIOUS_TAG" == "$TAG" ]]; then
  echo "${ENVIRONMENT} is already at ${TAG}; verifying only"
else
  sed -i "s/newTag: \".*\"/newTag: \"${TAG}\"/" "$KUSTOMIZATION"
  git commit --quiet -m "deploy(${ENVIRONMENT}): ${PREVIOUS_TAG} -> ${TAG}" "$KUSTOMIZATION"
  git push --quiet origin HEAD:main
  DEPLOY_COMMIT=$(git rev-parse HEAD)
  echo "Committed ${DEPLOY_COMMIT}: ${ENVIRONMENT} ${PREVIOUS_TAG} -> ${TAG}"
fi

if wait_for_sync "$TAG" && verify_rollout && smoke_test "$TAG"; then
  echo "Deployment of ${TAG} to ${ENVIRONMENT} succeeded"
  exit 0
fi

echo "::error::Deployment of ${TAG} to ${ENVIRONMENT} failed"
if [[ -z "$DEPLOY_COMMIT" ]]; then
  echo "Nothing was changed by this run, so there is nothing to roll back"
  exit 1
fi

echo "Rolling back: reverting ${DEPLOY_COMMIT}"
git pull --rebase --quiet origin main
git revert --no-edit "$DEPLOY_COMMIT" >/dev/null
git push --quiet origin HEAD:main
if wait_for_sync "$PREVIOUS_TAG" && verify_rollout && smoke_test "$PREVIOUS_TAG"; then
  echo "Rollback to ${PREVIOUS_TAG} succeeded; ${ENVIRONMENT} is healthy on the previous version"
else
  echo "::error::Rollback to ${PREVIOUS_TAG} did not verify — manual intervention needed"
fi
# The workflow still fails: the requested version was not deployed.
exit 1
