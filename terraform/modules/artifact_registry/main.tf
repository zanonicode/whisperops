resource "google_artifact_registry_repository" "whisperops_images" {
  project       = var.project_id
  location      = var.region
  repository_id = "whisperops-images"
  description   = "Docker images for the whisperops platform (sandbox, chat-frontend, platform-bootstrap, budget-controller)."
  format        = "DOCKER"

  cleanup_policies {
    id     = "keep-latest-10"
    action = "KEEP"
    most_recent_versions {
      keep_count = 10
    }
  }

  labels = var.labels
}
