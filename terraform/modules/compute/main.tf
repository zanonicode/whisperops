resource "google_compute_instance" "vm" {
  project      = var.project_id
  name         = "whisperops-vm"
  machine_type = var.vm_machine_type
  zone         = var.zone

  tags = ["whisperops-vm"]

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2204-lts"
      size  = 100
      type  = "pd-ssd"
    }
  }

  network_interface {
    subnetwork = var.subnet_self_link

    access_config {
      nat_ip = var.static_ip_address
    }
  }

  service_account {
    email  = var.bootstrap_sa_email
    scopes = ["cloud-platform"]
  }

  metadata_startup_script = file("${path.module}/startup-script.sh")

  metadata = {
    enable-oslogin = "TRUE"
  }

  lifecycle {
    ignore_changes = [
      # Ignore changes to metadata_startup_script after first boot
      # to avoid spurious replacements when script content is updated.
      metadata_startup_script,
    ]
  }
}
