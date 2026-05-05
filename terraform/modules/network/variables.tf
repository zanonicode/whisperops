variable "project_id" {
  description = "GCP project ID."
  type        = string
}

variable "region" {
  description = "GCP region for regional resources (subnet, static IP)."
  type        = string
}

variable "allowed_ssh_cidr" {
  description = "CIDR range permitted to connect on TCP/22. Restrict in production."
  type        = string
}
