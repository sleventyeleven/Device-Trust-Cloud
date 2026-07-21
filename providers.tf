# Google Cloud Provider configuration
provider "google" {
  region  = var.region
  project = var.project_id

  # Optional: impersonate a service account instead of using the default credentials
  impersonate_service_account = var.impersonate_service_account != "" ? var.impersonate_service_account : null
}

provider "google-beta" {
  region  = var.region
  project = var.project_id

  impersonate_service_account = var.impersonate_service_account != "" ? var.impersonate_service_account : null
}