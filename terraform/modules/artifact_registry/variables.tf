variable "project_id" {
  description = "GCP project ID."
  type        = string
}

variable "region" {
  description = "GCP region where the Artifact Registry repository will be created."
  type        = string
}

variable "labels" {
  description = "Labels to apply to the Artifact Registry repository."
  type        = map(string)
  default     = {}
}
