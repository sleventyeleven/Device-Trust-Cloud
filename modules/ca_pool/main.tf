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

# IAM is granted at the CA pool level (Google Private CA has no per-CertificateAuthority IAM resource).
# The root pool should have no standing access by default - it's only ever touched
# manually to sign a new intermediate every few years - so this binding is only
# created at all when the caller explicitly passes members for it. An
# _iam_binding resource can't hold an empty members list.
resource "google_privateca_ca_pool_iam_binding" "root_pool_issuer" {
  count = length(var.root_ca_pool_iam_members) > 0 ? 1 : 0

  ca_pool = google_privateca_ca_pool.root_pool.id
  role    = "roles/privateca.certificateRequester"
  members = var.root_ca_pool_iam_members
}

resource "google_privateca_ca_pool_iam_binding" "ca_pool_issuer" {
  ca_pool = google_privateca_ca_pool.ca_pool.id
  role    = "roles/privateca.certificateRequester"
  members = var.ca_pool_iam_members
}

# step-ca's cloudCAS RA client calls GetCertificateAuthority (to fetch the
# intermediate's own metadata/cert), which certificateRequester does not
# cover. privateca.viewer is the minimal role that includes it.
resource "google_privateca_ca_pool_iam_binding" "ca_pool_viewer" {
  ca_pool = google_privateca_ca_pool.ca_pool.id
  role    = "roles/privateca.viewer"
  members = var.ca_pool_iam_members
}

# roles/privateca.templateUser is bound on the CertificateTemplate resource, not the CA pool
# (see modules/certificate_template).
