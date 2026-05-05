resource "google_compute_network" "vpc" {
  project                 = var.project_id
  name                    = "whisperops-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "subnet" {
  project       = var.project_id
  name          = "whisperops-subnet"
  ip_cidr_range = "10.10.0.0/24"
  region        = var.region
  network       = google_compute_network.vpc.self_link
}

resource "google_compute_address" "static_ip" {
  project = var.project_id
  name    = "whisperops-static-ip"
  region  = var.region
}

resource "google_compute_firewall" "allow_ssh" {
  project = var.project_id
  name    = "allow-ssh"
  network = google_compute_network.vpc.self_link

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = [var.allowed_ssh_cidr]
  target_tags   = ["whisperops-vm"]

  description = "Allow SSH access from the configured CIDR. Restrict in production."
}

resource "google_compute_firewall" "allow_http_https" {
  project = var.project_id
  name    = "allow-http-https"
  network = google_compute_network.vpc.self_link

  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["whisperops-vm"]

  description = "Allow inbound HTTP and HTTPS traffic to whisperops VM."
}
