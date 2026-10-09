variable "project" {
  description = "Name prefix for every resource, so they are identifiable in the Vultr portal."
  type        = string
  default     = "vultr-devops"
}

variable "environment" {
  description = "Environment name, used in labels."
  type        = string
  default     = "prod"
}

variable "region" {
  description = "Vultr region ID for the cluster. blr = Bangalore."
  type        = string
  default     = "blr"
}

variable "kubernetes_version" {
  description = "VKE version string, exactly as returned by GET /v2/kubernetes/versions."
  type        = string
  # Spec requires 1.35+. VKE offered 1.35, 1.36 and 1.37 at build time; 1.35 is
  # the oldest and therefore most patched line that still meets the spec.
  default = "v1.35.9+2"
}

variable "node_plan" {
  description = "Vultr plan ID for worker nodes."
  type        = string
  # 4 vCPU / 8 GB. Istio ambient, three databases, Prometheus, Grafana and a
  # secrets operator do not fit on 4 GB nodes without evictions.
  default = "vc2-4c-8gb"
}

variable "node_count" {
  description = "Number of worker nodes."
  type        = number
  # Three nodes so pod anti-affinity can spread replicas and a PodDisruptionBudget
  # still holds while one node is drained.
  default = 3
}

variable "registry_region" {
  description = "Vultr Container Registry region. Registries exist in fewer regions than VKE."
  type        = string
  default     = "blr"
}

variable "registry_plan" {
  description = "Container registry plan (start_up, business, premium, enterprise)."
  type        = string
  default     = "start_up"
}
