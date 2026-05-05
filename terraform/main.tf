terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
  required_version = ">= 1.7"
}

provider "google" {
  project = var.project_id
  region  = var.region
}

locals {
  common_labels = {
    project    = var.project_id
    managed_by = "terraform"
  }
}

###############################################################################
# Network: VPC + subnet + firewall (terraform-google-modules/network)
###############################################################################

module "network" {
  source  = "terraform-google-modules/network/google"
  version = "18.1.0"

  project_id   = var.project_id
  network_name = "whisperops-vpc"
  routing_mode = "REGIONAL"

  subnets = [
    {
      subnet_name   = "whisperops-subnet"
      subnet_ip     = "10.10.0.0/24"
      subnet_region = var.region
    },
  ]

  ingress_rules = [
    {
      name          = "allow-ssh"
      description   = "Allow SSH access from the configured CIDR. Restrict in production."
      source_ranges = [var.allowed_ssh_cidr]
      target_tags   = ["whisperops-vm"]
      allow = [
        {
          protocol = "tcp"
          ports    = ["22"]
        },
      ]
    },
    {
      name          = "allow-http-https"
      description   = "Allow inbound HTTP and HTTPS traffic to whisperops VM."
      source_ranges = ["0.0.0.0/0"]
      target_tags   = ["whisperops-vm"]
      allow = [
        {
          protocol = "tcp"
          ports    = ["80", "443"]
        },
      ]
    },
  ]
}

# Static external regional IP for the VM (network module does not expose this).
resource "google_compute_address" "static_ip" {
  project = var.project_id
  name    = "whisperops-static-ip"
  region  = var.region
}

###############################################################################
# IAM: bootstrap service account (terraform-google-modules/service-accounts)
###############################################################################

module "bootstrap_sa" {
  source  = "terraform-google-modules/service-accounts/google"
  version = "4.7.0"

  project_id    = var.project_id
  names         = ["whisperops-bootstrap"]
  display_name  = "WhisperOps Bootstrap SA"
  description   = "Narrowly-scoped SA used by the whisperops VM during IDP bootstrap. Restricted to agent-* buckets and SAs via IAM Conditions."
  project_roles = []
}

# IAM bindings with CEL Conditions are kept inline because
# terraform-google-modules/iam/google does not support `condition` blocks.

resource "google_project_iam_member" "bootstrap_storage_admin" {
  project = var.project_id
  role    = "roles/storage.admin"
  member  = "serviceAccount:${module.bootstrap_sa.email}"

  condition {
    title       = "agent-buckets-only"
    description = "Restrict storage admin to agent-prefixed buckets."
    expression  = <<-EOT
      resource.name.startsWith("projects/_/buckets/agent-") ||
      resource.name.startsWith("projects/_/buckets/${var.project_id}-agent-")
    EOT
  }
}

resource "google_project_iam_member" "bootstrap_sa_admin" {
  project = var.project_id
  role    = "roles/iam.serviceAccountAdmin"
  member  = "serviceAccount:${module.bootstrap_sa.email}"

  condition {
    title       = "agent-service-accounts-only"
    description = "Restrict service account admin to agent-prefixed service accounts."
    expression  = "resource.name.startsWith(\"projects/${var.project_id}/serviceAccounts/agent-\")"
  }
}

resource "google_project_iam_member" "bootstrap_sa_key_admin" {
  project = var.project_id
  role    = "roles/iam.serviceAccountKeyAdmin"
  member  = "serviceAccount:${module.bootstrap_sa.email}"

  condition {
    title       = "agent-service-account-keys-only"
    description = "Restrict service account key admin to agent-prefixed service accounts."
    expression  = "resource.name.startsWith(\"projects/${var.project_id}/serviceAccounts/agent-\")"
  }
}

###############################################################################
# Storage: datasets bucket (terraform-google-modules/cloud-storage)
#
# The tfstate bucket is pre-created manually by the operator before the first
# `terraform init` (it has to exist before Terraform can use it as a backend),
# so it is intentionally NOT managed here.
###############################################################################

module "datasets_bucket" {
  source  = "terraform-google-modules/cloud-storage/google//modules/simple_bucket"
  version = "12.3.0"

  project_id               = var.project_id
  name                     = "${var.project_id}-datasets"
  location                 = var.region
  force_destroy            = false
  versioning               = true
  bucket_policy_only       = true
  public_access_prevention = "enforced"
  labels                   = local.common_labels
}

###############################################################################
# Compute: instance template + compute_instance (terraform-google-modules/vm)
###############################################################################

module "vm_instance_template" {
  source  = "terraform-google-modules/vm/google//modules/instance_template"
  version = "15.2.0"

  project_id           = var.project_id
  region               = var.region
  name_prefix          = "whisperops-vm"
  machine_type         = var.vm_machine_type
  source_image_family  = "ubuntu-2204-lts"
  source_image_project = "ubuntu-os-cloud"

  disk_size_gb = "100"
  disk_type    = "pd-ssd"

  subnetwork = module.network.subnets_self_links[0]

  tags   = ["whisperops-vm"]
  labels = local.common_labels

  startup_script = file("${path.module}/files/startup-script.sh")

  metadata = {
    enable-oslogin = "TRUE"
  }

  service_account = {
    email  = module.bootstrap_sa.email
    scopes = ["cloud-platform"]
  }

  # Module would otherwise create a new SA; we use bootstrap_sa instead.
  create_service_account = false

  # Public IP is configured here (on the template) — the compute_instance
  # submodule silently ignores access_config when the template defines the NIC.
  access_config = [
    {
      nat_ip       = google_compute_address.static_ip.address
      network_tier = "PREMIUM"
    },
  ]
}

module "vm" {
  source  = "terraform-google-modules/vm/google//modules/compute_instance"
  version = "15.2.0"

  project_id          = var.project_id
  region              = var.region
  zone                = var.zone
  hostname            = "whisperops-vm"
  add_hostname_suffix = false
  num_instances       = 1
  instance_template   = module.vm_instance_template.self_link
  deletion_protection = false

  static_ips = [google_compute_address.static_ip.address]
}
