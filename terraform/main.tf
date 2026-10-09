locals {
  name = "${var.project}-${var.environment}"

  # Vultr's API has no generic tag field on VKE clusters or registries, so
  # "tagging" is done two ways: a consistent name prefix on every resource, and
  # these Kubernetes labels on the nodes.
  node_labels = {
    project     = var.project
    environment = var.environment
    managed-by  = "terraform"
  }
}

resource "vultr_kubernetes" "this" {
  label   = local.name
  region  = var.region
  version = var.kubernetes_version

  # Single control plane. HA control planes cost extra and cannot be turned off
  # once enabled; for a short-lived assignment cluster the workloads' own HA
  # (replicas, anti-affinity, PDBs) is what is being demonstrated.
  ha_controlplanes = false

  node_pools {
    label         = "${local.name}-default"
    plan          = var.node_plan
    node_quantity = var.node_count

    # Fixed size. The cluster autoscaler is listed as a suggested advancement;
    # pod-level scaling is handled by HPAs.
    auto_scaler = false

    dynamic "labels" {
      for_each = local.node_labels
      content {
        key   = labels.key
        value = labels.value
      }
    }
  }
}

# The kube_config attribute on the cluster resource is deprecated in the
# provider; the kubeconfig is now read through this data source.
data "vultr_kubernetes_kubeconfig" "this" {
  cluster_id = vultr_kubernetes.this.id
}

resource "vultr_container_registry" "this" {
  # Registry names must be lowercase alphanumeric, hence no hyphens.
  name   = replace(local.name, "-", "")
  region = var.registry_region
  plan   = var.registry_plan

  # Private: images are pulled with an imagePullSecret, not anonymously.
  public = false
}
