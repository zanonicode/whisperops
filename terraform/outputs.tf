output "vm_external_ip" {
  description = "External NAT IP currently assigned to whisperops-vm by GCP. May differ from google_compute_address.static_ip.address if GCP assigned ephemeral NAT (compute_instance silently ignores static_ips when the instance template already defines the NIC)."
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
  description = "Base URL for the whisperops-images Artifact Registry repository."
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/whisperops-images"
}

output "tempo_blocks_bucket" {
  description = "Name of the GCS bucket for Tempo trace blocks (consumed by make tempo-gcs-key)."
  value       = module.tempo_blocks_bucket.name
}

output "tempo_writer_sa_email" {
  description = "Service account email for Tempo GCS writer (consumed by make tempo-gcs-key)."
  value       = google_service_account.tempo_writer.email
}

output "grafana_gcm_sa_email" {
  description = "Service account email for Grafana Cloud Monitoring reader (consumed by make grafana-gcm-key)."
  value       = google_service_account.grafana_gcm.email
}

output "langfuse_pg_connection_name" {
  description = "Cloud SQL connection name for the Langfuse Postgres instance (consumed by Cloud SQL Auth Proxy)."
  value       = module.langfuse_postgres.instance_connection_name
}

output "langfuse_pg_database_url" {
  description = "Postgres connection URL for Langfuse (user:password@127.0.0.1:5432/langfuse via Auth Proxy)."
  value       = "postgres://langfuse:${random_password.langfuse_db.result}@127.0.0.1:5432/langfuse"
  sensitive   = true
}

output "langfuse_cloudsql_proxy_sa_email" {
  description = "Service account email for the Langfuse Cloud SQL Auth Proxy sidecar (consumed by make langfuse-pg-key)."
  value       = google_service_account.langfuse_cloudsql_proxy.email
}

output "langfuse_nextauth_secret" {
  description = "NEXTAUTH_SECRET for Langfuse self-host (persisted in TF state across destroy/redeploy)."
  value       = random_password.langfuse_nextauth_secret.result
  sensitive   = true
}

output "langfuse_encryption_key" {
  description = "ENCRYPTION_KEY for Langfuse at-rest API-key encryption (64-char hex / 256-bit)."
  value       = random_id.langfuse_encryption_key.hex
  sensitive   = true
}

output "langfuse_salt" {
  description = "SALT for Langfuse password hashing."
  value       = random_password.langfuse_salt.result
  sensitive   = true
}
