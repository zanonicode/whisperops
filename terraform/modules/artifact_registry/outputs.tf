output "registry_url" {
  description = "Base URL for the whisperops-images Artifact Registry repository."
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/whisperops-images"
}

output "repository_id" {
  description = "Artifact Registry repository resource ID."
  value       = google_artifact_registry_repository.whisperops_images.id
}
