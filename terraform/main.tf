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

module "network" {
  source = "./modules/network"

  project_id       = var.project_id
  region           = var.region
  allowed_ssh_cidr = var.allowed_ssh_cidr
}

module "iam" {
  source = "./modules/iam"

  project_id = var.project_id
}

module "storage" {
  source = "./modules/storage"

  project_id = var.project_id
  region     = var.region
}

module "compute" {
  source = "./modules/compute"

  project_id         = var.project_id
  zone               = var.zone
  vm_machine_type    = var.vm_machine_type
  subnet_self_link   = module.network.subnet_self_link
  static_ip_address  = module.network.static_ip_address
  bootstrap_sa_email = module.iam.bootstrap_sa_email
}
