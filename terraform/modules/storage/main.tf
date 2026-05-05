resource "google_storage_bucket" "tfstate" {
  project  = var.project_id
  name     = "${var.project_id}-tfstate"
  location = var.region

  force_destroy               = false
  uniform_bucket_level_access = true

  versioning {
    enabled = true
  }

  # State buckets are private by definition; enforce it explicitly.
  public_access_prevention = "enforced"
}

resource "google_storage_bucket" "datasets" {
  project  = var.project_id
  name     = "${var.project_id}-datasets"
  location = var.region

  force_destroy               = false
  uniform_bucket_level_access = true

  versioning {
    enabled = true
  }

  public_access_prevention = "enforced"
}
