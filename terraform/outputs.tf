output "vm_external_ip" {
  description = "Static external IP address of the whisperops GCE VM."
  value       = module.network.static_ip_address
}

output "datasets_bucket_name" {
  description = "Name of the GCS bucket used for whisperops datasets."
  value       = module.storage.datasets_bucket_name
}

output "bootstrap_sa_email" {
  description = "Email of the whisperops bootstrap service account."
  value       = module.iam.bootstrap_sa_email
}

output "kubeconfig_path" {
  description = "Path to the kubeconfig written by the VM startup script."
  value       = "~/.kube/config"
}
