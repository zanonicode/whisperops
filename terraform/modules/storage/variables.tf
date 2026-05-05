variable "project_id" {
  description = "GCP project ID. Used as a prefix for bucket names."
  type        = string
}

variable "region" {
  description = "GCP region for bucket location."
  type        = string
}
