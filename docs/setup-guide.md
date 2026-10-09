# Setup and Deployment Guide

How to build this platform from an empty Vultr account, deploy the
application, and roll it back.

## 1. Prerequisites

### Tools

| Tool | Version used | Purpose |
|---|---|---|
| Terraform | 1.16 (needs ≥ 1.10) | Infrastructure; 1.10+ for S3 lockfile state locking |
| kubectl | 1.36 | Cluster access; includes Kustomize (`kubectl apply -k`) |
| Helm | 4.3 | Bootstrap components |
| Docker + Buildx | 29 / 0.30 | Local image builds (CI builds the real ones) |
| GitHub CLI (`gh`) | 2.45 | Deploy key and Actions secrets |
| curl, openssl, python3, git | any | Used by the install scripts |

### Vultr account

1. Create an API key (Account → API) and add your public IP to its access
   control list. A key that is not allow-listed fails with an opaque auth error.
2. Put credentials in a git-ignored `.env` file in the repository root:

   ```bash
   VULTR_API_KEY=...
   AWS_ACCESS_KEY_ID=...        # added in step 2.1
   AWS_SECRET_ACCESS_KEY=...    # added in step 2.1
   ```

   Load it in each shell with `set -a; . ./.env; set +a`.

## 2. Infrastructure provisioning

### 2.1 Create the Terraform state bucket (once)

Terraform cannot keep its state in a bucket it has not created yet, so the
bucket is created first, outside Terraform.

```bash
# Object storage subscription: Bangalore (cluster 7), Standard tier (2)
curl -s -X POST https://api.vultr.com/v2/object-storage \
  -H "Authorization: Bearer $VULTR_API_KEY" -H 'Content-Type: application/json' \
  -d '{"cluster_id":7,"tier_id":2,"label":"vultr-devops-tfstate"}'

# When its status is "active", read s3_access_key / s3_secret_key from
#   GET https://api.vultr.com/v2/object-storage/<id>
# and add them to .env as AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY.

# Create the bucket and turn on versioning (recover from a bad state write)
s3() { curl -s --aws-sigv4 "aws:amz:us-east-1:s3" \
         --user "$AWS_ACCESS_KEY_ID:$AWS_SECRET_ACCESS_KEY" "$@"; }
s3 -X PUT https://blr1.vultrobjects.com/<bucket-name>
s3 -X PUT "https://blr1.vultrobjects.com/<bucket-name>?versioning" \
   -H 'Content-Type: application/xml' \
   -d '<VersioningConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Status>Enabled</Status></VersioningConfiguration>'
```

Bucket names are unique per storage cluster; this deployment uses
`arnav1511-vke-tfstate`.

### 2.2 Provision the cluster and registry

```bash
cd terraform
cp backend.hcl.example backend.hcl      # set the bucket name
terraform init -backend-config=backend.hcl
terraform plan -out=tfplan
terraform apply tfplan                  # about 6 minutes
```

Creates the VKE cluster (Kubernetes 1.35, 3 × `vc2-4c-8gb`) and a private
container registry. Variables and their reasoning are in `variables.tf`.

### 2.3 Cluster access

**Owner (admin):**

```bash
terraform output -raw kubeconfig | base64 -d > ~/.kube/vke-vultr-devops.yaml
chmod 600 ~/.kube/vke-vultr-devops.yaml
export KUBECONFIG=~/.kube/vke-vultr-devops.yaml
kubectl get nodes
```

**Reviewer (read-only, expires after 7 days):**

```bash
./bootstrap/ci-access/reviewer-kubeconfig.sh > reviewer.kubeconfig
```

The resulting file can view workloads, services, config and events in every
namespace, but cannot read Secrets or change anything. Send it over a private
channel; do not commit it.

**CI:** a separate service account limited to watching rollouts (section 3).

## 3. Cluster bootstrap

Run in this order — each step depends on the ones before it. Every script is
safe to re-run.

| # | Command | Installs | Depends on |
|---|---|---|---|
| 1 | `bootstrap/istio/install.sh` | Gateway API CRDs, Istio ambient, mesh-wide STRICT mTLS | — |
| 2 | `bootstrap/cert-manager/install.sh` | cert-manager, Let's Encrypt issuer | Gateway API CRDs |
| 3 | `kubectl apply -f bootstrap/gateway/gateway.yaml` | Public Gateway, HTTPS listeners, HTTP→HTTPS redirect | 1, 2 |
| 4 | `bootstrap/observability/install.sh` | metrics-server, Prometheus, Alertmanager, Grafana, alert rules, dashboards | 1, 3 |
| 5 | `bootstrap/databases/install.sh` | PostgreSQL, MongoDB, Valkey | 4 (ServiceMonitor CRD) |
| 6 | `bootstrap/secrets/install.sh` | Vault, Vault Secrets Operator, policies, seeded secrets | 5; Terraform env loaded |
| 7 | `bootstrap/policy/install.sh` | Admission webhook | 2 |
| 8 | `bootstrap/argocd/install.sh` | Argo CD, deploy key, three Applications | 6, 7; `gh` logged in |
| 9 | `bootstrap/ci-access/install.sh` | CI service account, GitHub Actions secrets | 8; `gh` logged in |

### After step 3: set the hostnames

The hostnames embed the load balancer IP (`<name>.<ip>.sslip.io`). On a new
cluster the IP is different, so read it and replace the old one everywhere:

```bash
kubectl -n ingress get gateway public -o jsonpath='{.status.addresses[0].value}'
grep -rl '139.84.159.60' --exclude-dir=.git . | xargs sed -i 's/139\.84\.159\.60/<new-ip>/g'
kubectl apply -f bootstrap/gateway/gateway.yaml
kubectl -n ingress get certificate      # READY=True within about a minute
```

### After step 6: keep the Vault keys safe

`bootstrap/secrets/.vault-init.json` (git-ignored) holds the unseal key and
root token. Without it Vault cannot be unsealed after a restart. Back it up
somewhere private.

### Verifying the bootstrap

```bash
kubectl get pods -A | grep -v Running            # expect only the header
kubectl get gateway -n ingress                   # PROGRAMMED=True
kubectl get certificate -n ingress               # READY=True
kubectl get applications -n argocd               # Synced / Healthy
kubectl get vaultstaticsecret -A                 # all synced
```

## 4. Application deployment

### Normal path: push to `main`

```
edit app/** → pull request → build-scan runs (build + Trivy + SBOM, no push)
            → merge → images pushed as :<short-sha>
            → deploy: dev → staging → prod, each verified and smoke-tested
```

Nothing is applied by hand. The deploy job commits the new tag to
`k8s/overlays/<env>/kustomization.yaml` and Argo CD applies it.

### Manifest-only changes

Edit files under `k8s/` and push. Argo CD picks the change up within three
minutes; no pipeline is involved.

### Deploying a specific version manually

```bash
gh workflow run deploy.yaml -f tag=<short-sha>
gh run watch
```

The tag must exist in the registry. This is also how to roll *forward* to a
fix or redeploy a known-good version.

### First deployment on a new cluster

Argo CD (step 8) deploys whatever tag the overlays reference, so the images
must exist first:

```bash
SHA=$(git rev-parse --short HEAD)
REG=$(terraform -chdir=terraform output -raw registry_urn)
terraform -chdir=terraform output -raw registry_password | \
  docker login "${REG%%/*}" -u "$(terraform -chdir=terraform output -raw registry_username)" --password-stdin
docker buildx create --name multiarch --driver docker-container --use
for c in backend frontend; do
  docker buildx build --platform linux/amd64,linux/arm64 \
    --build-arg VERSION=$SHA -t $REG/$c:$SHA --push app/$c
done
sed -i "s/newTag: \".*\"/newTag: \"$SHA\"/" k8s/overlays/*/kustomization.yaml
git commit -am "Deploy $SHA" && git push
```

### Checking a deployment

```bash
kubectl -n app-prod get deploy,hpa,pdb,pods -o wide
kubectl -n app-prod rollout status deploy/backend
curl -s https://app.139.84.159.60.sslip.io/api/status
```

## 5. Rollback procedures

### Automatic

If a rollout does not complete or a smoke test fails, the deploy job reverts
its own commit, waits for Argo CD to restore the previous version, re-verifies
it, and fails the workflow. Later environments are not touched.

Because rolling updates use `maxUnavailable: 0`, a version that cannot start
never replaces a working pod, so users are served by the old version
throughout.

### Manual

Every deployment is one commit named `deploy(<env>): <old> -> <new>`.

```bash
git log --oneline -- k8s/overlays/prod/kustomization.yaml   # find the commit
git revert <commit> && git push                             # roll back
kubectl -n app-prod rollout status deploy/backend           # confirm
```

or redeploy an earlier tag through the pipeline, which also runs the smoke
tests:

```bash
gh workflow run deploy.yaml -f tag=<previous-short-sha>
```

**Do not use `kubectl rollout undo`.** Argo CD's self-heal reverts it within
seconds, because git still names the newer version.

### Emergency: stop Argo CD reconciling

To make a manual change stick while investigating:

```bash
kubectl -n argocd patch application app-prod --type merge \
  -p '{"spec":{"syncPolicy":{"automated":null}}}'
# ...investigate...
kubectl apply -f bootstrap/argocd/applications.yaml          # re-enable
```

### Infrastructure

Terraform state is versioned in the bucket. To undo an infrastructure change,
revert the commit and run `terraform plan` / `apply` again.

## 6. Operations

| Task | Command |
|---|---|
| Grafana admin password | `kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' \| base64 -d` |
| Prometheus UI | `kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090` |
| Argo CD UI | `kubectl -n argocd port-forward svc/argocd-server 8080:80`; password: `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' \| base64 -d` |
| Unseal Vault after a restart | `bootstrap/secrets/unseal.sh` |
| Rotate a database password | Change it in the database, then `vault kv patch secret/app/databases <key>=<value>`; the operator syncs it and restarts the backend |
| Confirm mTLS is enforced | `kubectl -n default run t --rm -it --restart=Never --image=curlimages/curl -- curl -m 5 http://backend.app-prod/api/status` must fail |
| Test the admission webhook | `kubectl -n app-dev run bad --image=nginx:latest --dry-run=server` must be denied |

**`kubectl proxy`-style access to mesh services does not work** (the API
server is outside the mesh and STRICT mTLS rejects it). Use `port-forward`.

## 7. Teardown

```bash
kubectl delete -f bootstrap/argocd/applications.yaml   # removes the app namespaces
kubectl delete -f bootstrap/gateway/gateway.yaml       # releases the load balancer
kubectl delete pvc --all -A                            # releases block volumes
cd terraform && terraform destroy
# then delete the object storage subscription in the Vultr portal
```

Delete the Gateway and volumes *before* `terraform destroy`: the load balancer
and block volumes are created by Kubernetes, not Terraform, and would
otherwise be left behind and keep billing.
