output "vm_external_ip" {
  description = "External NAT IP currently assigned to whisperops-vm by GCP. May differ from google_compute_address.static_ip.address if GCP assigned ephemeral NAT — see DD-39."
  value       = data.google_compute_instance.vm.network_interface[0].access_config[0].nat_ip
}

output "datasets_bucket_name" {
  description = "Name of the GCS bucket used for whisperops datasets."
  value       = module.datasets_bucket.name
}

output "bootstrap_sa_email" {
  description = "Email of the whisperops bootstrap service account."
  value       = module.bootstrap_sa.email
}

output "kubeconfig_path" {
  description = "Path to the kubeconfig written by the VM startup script."
  value       = "~/.kube/config"
}

output "registry_url" {
  description = "Base URL for the whisperops-images Artifact Registry repository (DD-14)."
  value       = module.artifact_registry.registry_url
}
