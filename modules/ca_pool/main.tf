# CA Pool Module
# Creates a shared Enterprise-tier CA pool for both root and intermediate CAs

resource "google_privateca_ca_pool" "root_pool" {
  name     = var.root_ca_pool_name
  location = var.location
  tier     = "ENTERPRISE"

  # Publishing options
  publishing_options {
    publish_ca_cert = var.enable_root_publishing
    publish_crl     = var.enable_root_publishing
  }
}

resource "google_privateca_ca_pool" "ca_pool" {
  name     = var.ca_pool_name
  location = var.location
  tier     = var.ca_pool_tier

  # Publishing options
  publishing_options {
    publish_ca_cert = var.enable_publishing
    publish_crl     = var.enable_publishing
  }
}

# IAM is granted at the CA pool level (Google Private CA has no per-CertificateAuthority IAM resource)
resource "google_privateca_ca_pool_iam_binding" "root_pool_issuer" {
  ca_pool = google_privateca_ca_pool.root_pool.id
  role    = "roles/privateca.issuer"
  members = var.root_ca_pool_iam_members
}

resource "google_privateca_ca_pool_iam_binding" "ca_pool_issuer" {
  ca_pool = google_privateca_ca_pool.ca_pool.id
  role    = "roles/privateca.issuer"
  members = var.ca_pool_iam_members
}

resource "google_privateca_ca_pool_iam_binding" "ca_pool_template_user" {
  ca_pool = google_privateca_ca_pool.ca_pool.id
  role    = "roles/privateca.templateUser"
  members = var.ca_pool_iam_members
}
