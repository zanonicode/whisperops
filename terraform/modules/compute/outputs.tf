output "vm_instance_name" {
  description = "Name of the whisperops GCE instance."
  value       = google_compute_instance.vm.name
}

output "vm_self_link" {
  description = "Self-link of the whisperops GCE instance."
  value       = google_compute_instance.vm.self_link
}
