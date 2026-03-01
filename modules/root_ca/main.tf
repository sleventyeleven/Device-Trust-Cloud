# Root CA Module
# Creates a root Certificate Authority with 10-year lifetime and deletion protection

resource "google_privateca_certificate_authority" "root_ca" {
  pool = google_privateca_ca_pool.root_pool.name
  certificate_authority_id = var.root_ca_name

  # Key specification
  key_spec {
    algorithm = var.key_algorithm
  }

  # CA certificate lifetime (default: 10 years)
  lifetime = var.lifetime

  # Deletion protection for security
  deletion_protection = true

  # CA configuration
  subject {
    common_name = var.root_ca_name
    organization = "Device Trust Infrastructure"
    country = "US"
  }

  # Publishing configuration
  publishing_config {
    # Optional: Publish to Cloud Storage
    gcs_bucket = var.root_ca_gcs_bucket
  }

  # Activate the CA
  activate = true

  description = "Root Certificate Authority for Device Trust"
}

# Grant IAM roles for root CA
# This is typically done by step-ca service account
resource "google_privateca_certificate_authority_iam_binding" "bind_issuer" {
  certificate_authority_id = google_privateca_certificate_authority.root_ca.certificate_authority_id
  role = "roles/privateca.issuer"

  members = var.root_ca_iam_members
}