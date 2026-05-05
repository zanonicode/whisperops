output "bootstrap_sa_email" {
  description = "Email address of the whisperops bootstrap service account."
  value       = google_service_account.bootstrap.email
}

output "bootstrap_sa_id" {
  description = "Fully-qualified resource ID of the whisperops bootstrap service account."
  value       = google_service_account.bootstrap.id
}
