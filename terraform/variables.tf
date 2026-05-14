variable "project_id" {
  description = "GCP project ID where all resources will be created."
  type        = string
}

variable "region" {
  description = "GCP region for regional resources."
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "GCP zone for the GCE VM."
  type        = string
  default     = "us-central1-a"
}

variable "vm_machine_type" {
  description = "Machine type for the whisperops GCE VM."
  type        = string
  default     = "e2-standard-8"
}

variable "allowed_ssh_cidr" {
  description = "CIDR range allowed to reach TCP/22 on the VM. Restrict in prod (e.g. your VPN egress IP)."
  type        = string
  default     = "0.0.0.0/0"
}

variable "tempo_blocks_bucket_name" {
  description = "Name of the GCS bucket for Tempo WAL blocks and trace storage."
  type        = string
  default     = "whisperops-tempo-blocks"
}

variable "langfuse_db_tier" {
  description = "Cloud SQL machine tier for the Langfuse Postgres instance."
  type        = string
  default     = "db-f1-micro"
}
