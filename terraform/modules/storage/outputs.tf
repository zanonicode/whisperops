output "tfstate_bucket_name" {
  description = "Name of the GCS bucket used for Terraform remote state."
  value       = google_storage_bucket.tfstate.name
}

output "datasets_bucket_name" {
  description = "Name of the GCS bucket used for whisperops datasets."
  value       = google_storage_bucket.datasets.name
}
