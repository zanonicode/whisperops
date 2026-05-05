variable "project_id" {
  description = "GCP project ID."
  type        = string
}

variable "zone" {
  description = "GCP zone in which to create the VM."
  type        = string
}

variable "vm_machine_type" {
  description = "Machine type for the GCE instance."
  type        = string
}

variable "subnet_self_link" {
  description = "Self-link of the subnet to attach the VM's network interface to."
  type        = string
}

variable "static_ip_address" {
  description = "Reserved static external IP address to assign to the VM."
  type        = string
}

variable "bootstrap_sa_email" {
  description = "Email of the service account to attach to the VM."
  type        = string
}
