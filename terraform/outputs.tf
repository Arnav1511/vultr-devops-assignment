output "cluster_id" {
  description = "VKE cluster ID."
  value       = vultr_kubernetes.this.id
}

output "cluster_endpoint" {
  description = "Kubernetes API server endpoint."
  value       = vultr_kubernetes.this.endpoint
}

output "kubeconfig" {
  description = "Base64-encoded kubeconfig. terraform output -raw kubeconfig | base64 -d > ~/.kube/vke.yaml"
  value       = data.vultr_kubernetes_kubeconfig.this.kube_config
  sensitive   = true
}

output "registry_urn" {
  description = "Registry URL to tag and push images to."
  value       = vultr_container_registry.this.urn
}

output "registry_username" {
  description = "Registry root username, for docker login and the imagePullSecret."
  value       = vultr_container_registry.this.root_user["username"]
  sensitive   = true
}

output "registry_password" {
  description = "Registry root password."
  value       = vultr_container_registry.this.root_user["password"]
  sensitive   = true
}
