# Observability cloud infrastructure — provisioned before the cluster starts
# (make deploy → tf-apply runs before helmfile). Rule #12: cluster-wide cloud
# resources belong in Terraform, not Crossplane. Rule #11: public modules only.
#
# Resources owned here:
#   - gs://whisperops-tempo-blocks  (Tempo GCS WAL/block backend)
#   - whisperops-tempo-writer SA    (roles/storage.objectAdmin on the bucket)
#   - whisperops-grafana-gcm SA     (roles/monitoring.viewer, project-wide)
#   - Cloud SQL Postgres "whisperops-langfuse-pg"  (Langfuse backend)
#   - whisperops-langfuse-pg-proxy SA (roles/cloudsql.client)
#
# ADRs: ADR-Obs-1 (Tempo bucket), ADR-Obs-2 (GCM SA), ADR-Obs-3 (Postgres)

###############################################################################
# Cloud SQL: enable required APIs
###############################################################################

resource "google_project_service" "sqladmin" {
  project            = var.project_id
  service            = "sqladmin.googleapis.com"
  disable_on_destroy = false
}

###############################################################################
# Tempo blocks bucket
# Public module: GoogleCloudPlatform/cloud-storage/google ~> 9.0 (Rule #11)
###############################################################################

module "tempo_blocks_bucket" {
  source  = "terraform-google-modules/cloud-storage/google"
  version = "~> 12.0"

  project_id = var.project_id
  location   = var.region
  prefix     = ""
  names      = [var.tempo_blocks_bucket_name]

  force_destroy = {
    "${var.tempo_blocks_bucket_name}" = true
  }

  versioning = {
    "${var.tempo_blocks_bucket_name}" = false
  }

  lifecycle_rules = [{
    action    = { type = "Delete" }
    condition = { age = 30 }
  }]

  depends_on = [google_project_service.platform_apis]
}

###############################################################################
# Tempo writer service account + bucket IAM
###############################################################################

resource "google_service_account" "tempo_writer" {
  project      = var.project_id
  account_id   = "whisperops-tempo-writer"
  display_name = "Tempo block writer"
  description  = "Writes Tempo WAL blocks to gs://whisperops-tempo-blocks. Inference-independent."
}

resource "google_storage_bucket_iam_member" "tempo_writer_binding" {
  bucket = module.tempo_blocks_bucket.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.tempo_writer.email}"
}

###############################################################################
# Grafana GCM (Stackdriver) service account + project IAM
# ADR-Obs-2: monitoring.viewer on the project — read-only Cloud Monitoring.
###############################################################################

resource "google_service_account" "grafana_gcm" {
  project      = var.project_id
  account_id   = "whisperops-grafana-gcm"
  display_name = "Grafana Cloud Monitoring reader"
  description  = "Read-only Cloud Monitoring access for Grafana Stackdriver datasource."
}

resource "google_project_iam_member" "grafana_gcm_viewer" {
  project = var.project_id
  role    = "roles/monitoring.viewer"
  member  = "serviceAccount:${google_service_account.grafana_gcm.email}"
}

###############################################################################
# Langfuse Cloud SQL Postgres
# Public module: terraform-google-modules/sql-db/google//modules/postgresql
# v28.1.0 (Rule #11, ADR-Obs-3)
###############################################################################

resource "random_password" "langfuse_db" {
  length  = 32
  special = false
}

module "langfuse_postgres" {
  source  = "terraform-google-modules/sql-db/google//modules/postgresql"
  version = "~> 28.1"

  project_id          = var.project_id
  name                = "whisperops-langfuse-pg"
  database_version    = "POSTGRES_15"
  region              = var.region
  zone                = var.zone
  tier                = var.langfuse_db_tier
  availability_type   = "ZONAL"
  disk_size           = 10
  disk_autoresize     = true
  deletion_protection = false

  user_name     = "langfuse"
  user_password = random_password.langfuse_db.result

  db_name = "langfuse"

  # Skip user/db DELETE API calls on destroy — let the parent SQL instance
  # destruction cascade. Required because Langfuse v3 grants the langfuse
  # role ownership of 85+ objects and holds active connections via the
  # cloud-sql-proxy sidecar, so PG rejects both DROP USER and DROP DATABASE.
  user_deletion_policy     = "ABANDON"
  database_deletion_policy = "ABANDON"

  ip_configuration = {
    ipv4_enabled                                  = true
    authorized_networks                           = []
    private_network                               = null
    require_ssl                                   = false
    ssl_mode                                      = null
    allocated_ip_range                            = null
    enable_private_path_for_google_cloud_services = false
  }

  depends_on = [google_project_service.sqladmin]
}

###############################################################################
# Cloud SQL Auth Proxy service account + IAM
###############################################################################

resource "google_service_account" "langfuse_cloudsql_proxy" {
  project      = var.project_id
  account_id   = "whisperops-langfuse-pg-proxy"
  display_name = "Langfuse Cloud SQL Auth Proxy"
  description  = "Used by Cloud SQL Auth Proxy sidecar in Langfuse pod."
}

resource "google_project_iam_member" "langfuse_proxy_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.langfuse_cloudsql_proxy.email}"
}

###############################################################################
# Langfuse application secrets — NEXTAUTH_SECRET / ENCRYPTION_KEY / SALT.
# Persisted in Terraform state so make destroy+deploy doesn't invalidate
# existing Langfuse users + API keys. ENCRYPTION_KEY must be 32 bytes / 256
# bits → 64-char hex (Langfuse requirement). SALT and NEXTAUTH_SECRET are
# 32-char random alphanumeric strings.
###############################################################################

resource "random_password" "langfuse_nextauth_secret" {
  length  = 32
  special = false
}

resource "random_id" "langfuse_encryption_key" {
  byte_length = 32
}

resource "random_password" "langfuse_salt" {
  length  = 32
  special = false
}
