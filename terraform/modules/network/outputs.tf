output "network_self_link" {
  description = "Self-link of the whisperops VPC network."
  value       = google_compute_network.vpc.self_link
}

output "subnet_self_link" {
  description = "Self-link of the whisperops subnet."
  value       = google_compute_subnetwork.subnet.self_link
}

output "static_ip_address" {
  description = "Reserved static external IP address for the VM."
  value       = google_compute_address.static_ip.address
}

output "static_ip_self_link" {
  description = "Self-link of the reserved static external IP address."
  value       = google_compute_address.static_ip.self_link
}
