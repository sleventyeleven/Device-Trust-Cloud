# Google Cloud Provider configuration
provider "google" {
  region  = var.region
  project = var.project_id

  # Optional: Use workload identity federation for secure authentication
  workload_identity_provider = var.workload_identity_provider
  workload_identity_pool = var.workload_identity_pool
  workload_identity_pool_provider = var.workload_identity_pool_provider
  impersonate_service_account = var.impersonate_service_account
}

provider "google-beta" {
  region  = var.region
  project = var.project_id

  workload_identity_provider = var.workload_identity_provider
  workload_identity_pool = var.workload_identity_pool
  workload_identity_pool_provider = var.workload_identity_pool_provider
  impersonate_service_account = var.impersonate_service_account
}