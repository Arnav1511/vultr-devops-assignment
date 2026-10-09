# Vultr DevOps Assignment

A 2-tier application on Vultr Kubernetes Engine with Istio Ambient, Gateway API,
Prometheus/Grafana, operator-managed secrets and GitHub Actions CI/CD.

| Path | Contents |
|---|---|
| `terraform/` | VKE cluster, container registry, remote state backend |
| `bootstrap/` | Helm values for Istio, databases, observability, secrets |
| `app/backend/` | Go REST API |
| `app/frontend/` | Static web UI served by a small Go server |
| `k8s/` | Kustomize base and dev/staging/prod overlays |
| `.github/workflows/` | Build-scan and deploy pipelines |
| `docs/` | Architecture and setup guide |

Work in progress — live URLs and documentation are added as the build proceeds.
