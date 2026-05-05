resource "google_service_account" "bootstrap" {
  project      = var.project_id
  account_id   = "whisperops-bootstrap"
  display_name = "WhisperOps Bootstrap SA"
  description  = "Narrowly-scoped SA used by the whisperops VM during IDP bootstrap. Restricted to agent-* buckets and SAs via IAM Conditions."
}

# Storage Admin scoped to agent-* buckets only.
resource "google_project_iam_member" "bootstrap_storage_admin" {
  project = var.project_id
  role    = "roles/storage.admin"
  member  = "serviceAccount:${google_service_account.bootstrap.email}"

  condition {
    title       = "agent-buckets-only"
    description = "Restrict storage admin to agent-prefixed buckets."
    expression  = <<-EOT
      resource.name.startsWith("projects/_/buckets/agent-") ||
      resource.name.startsWith("projects/_/buckets/${var.project_id}-agent-")
    EOT
  }
}

# Service Account Admin scoped to agent-* SAs only.
resource "google_project_iam_member" "bootstrap_sa_admin" {
  project = var.project_id
  role    = "roles/iam.serviceAccountAdmin"
  member  = "serviceAccount:${google_service_account.bootstrap.email}"

  condition {
    title       = "agent-service-accounts-only"
    description = "Restrict service account admin to agent-prefixed service accounts."
    expression  = "resource.name.startsWith(\"projects/${var.project_id}/serviceAccounts/agent-\")"
  }
}

# Service Account Key Admin scoped to agent-* SAs only.
resource "google_project_iam_member" "bootstrap_sa_key_admin" {
  project = var.project_id
  role    = "roles/iam.serviceAccountKeyAdmin"
  member  = "serviceAccount:${google_service_account.bootstrap.email}"

  condition {
    title       = "agent-service-account-keys-only"
    description = "Restrict service account key admin to agent-prefixed service accounts."
    expression  = "resource.name.startsWith(\"projects/${var.project_id}/serviceAccounts/agent-\")"
  }
}
