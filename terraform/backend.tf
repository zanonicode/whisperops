terraform {
  backend "gcs" {
    # bucket is supplied at init time via:
    #   terraform init -backend-config=envs/demo/backend.tfvars
    prefix = "whisperops/state"
  }
}
