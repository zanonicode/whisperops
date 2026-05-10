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
    {
      name          = "allow-kind-ingress"
      description   = "Allow inbound traffic to NGINX-Ingress on port 8443. Required for sslip.io external access."
      source_ranges = ["0.0.0.0/0"]
      target_tags   = ["whisperops-vm"]
      allow = [
        {
          protocol = "tcp"
          ports    = ["8443"]
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
  description   = "Bootstrap SA used by the whisperops VM. No IAM Conditions on *.create paths: CEL evaluates resource.name as empty at create time, causing 403 on every Crossplane SA/Key/IAMMember create."
  project_roles = []
}

# Bootstrap SA roles are granted unconditionally. CEL Conditions on
# resource.name only meaningfully filter get/update/delete; they evaluate to
# false on every *.create call (resource.name is empty at create time),
# breaking Crossplane reconciliation. Residual blast-radius risk is accepted.

resource "google_project_iam_member" "bootstrap_storage_admin" {
  project = var.project_id
  role    = "roles/storage.admin"
  member  = "serviceAccount:${module.bootstrap_sa.email}"
}

resource "google_project_iam_member" "bootstrap_sa_admin" {
  project = var.project_id
  role    = "roles/iam.serviceAccountAdmin"
  member  = "serviceAccount:${module.bootstrap_sa.email}"
}

resource "google_project_iam_member" "bootstrap_sa_key_admin" {
  project = var.project_id
  role    = "roles/iam.serviceAccountKeyAdmin"
  member  = "serviceAccount:${module.bootstrap_sa.email}"
}

# roles/resourcemanager.projectIamAdmin is required for the bootstrap SA to
# write google_project_iam_member resources via Crossplane: the GCP IAM
# provider issues ProjectIAMMember writes that need this role explicitly,
# distinct from serviceAccountAdmin which only manages the SA objects.
resource "google_project_iam_member" "bootstrap_project_iam_admin" {
  project = var.project_id
  role    = "roles/resourcemanager.projectIamAdmin"
  member  = "serviceAccount:${module.bootstrap_sa.email}"
}

###############################################################################
# Artifact Registry: whisperops-images repository
###############################################################################

module "artifact_registry" {
  source = "./modules/artifact_registry"

  project_id = var.project_id
  region     = var.region
  labels     = local.common_labels
}

# Grant the bootstrap SA write access to the AR repo so CI/CD and manual
# image pushes can use it (also required for the VM startup script to push
# images built on the VM itself).
resource "google_artifact_registry_repository_iam_member" "bootstrap_sa_ar_writer" {
  project    = var.project_id
  location   = var.region
  repository = "whisperops-images"
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${module.bootstrap_sa.email}"

  depends_on = [module.artifact_registry]
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

  project_id = var.project_id
  name       = "${var.project_id}-datasets"
  location   = var.region
  # Demo/learning environment: terraform destroy is the canonical teardown path
  # and is gated by an interactive confirmation in `make destroy`.
  # Set to false if this stack is ever promoted to a production-leaning context.
  force_destroy            = true
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

# Query the live VM to get its actual NAT IP. The instance_template
# access_config sets nat_ip = static_ip.address, but compute_instance silently
# ignores static_ips when the template already defines the NIC. The data source
# reflects whatever IP GCP has actually assigned.
data "google_compute_instance" "vm" {
  project    = var.project_id
  zone       = var.zone
  name       = "whisperops-vm"
  depends_on = [module.vm]
}
