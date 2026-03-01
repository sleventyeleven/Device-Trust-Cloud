# Intermediate CA Module
# Creates a subordinate Certificate Authority (5-year lifetime) controlled by step-ca

resource "google_privateca_certificate_authority" "intermediate_ca" {
  pool = google_privateca_ca_pool.ca_pool.name
  certificate_authority_id = var.intermediate_ca_name

  # Subordinate CA configuration
  subordinate_config {
    # Reference the root CA
    certificate_authority = google_privateca_certificate_authority.root_ca.name

    # Key specification
    key_spec {
      algorithm = var.key_algorithm
    }
  }

  # Type as SUBORDINATE
  type = "SUBORDINATE"

  # CA certificate lifetime (default: 5 years)
  lifetime = var.lifetime

  # Deletion protection for security
  deletion_protection = true

  # Activate the CA
  activate = true

  # Subject
  subject {
    common_name = var.intermediate_ca_name
    organization = "Device Trust Infrastructure"
    country = "US"
  }

  description = "Intermediate Certificate Authority for Device Trust"
}

# Grant IAM roles for intermediate CA
# This allows step-ca to issue certificates from this CA
resource "google_privateca_certificate_authority_iam_binding" "bind_issuer" {
  certificate_authority_id = google_privateca_certificate_authority.intermediate_ca.certificate_authority_id
  role = "roles/privateca.issuer"

  members = var.intermediate_ca_iam_members
}

# Grant IAM role for template usage
resource "google_privateca_certificate_authority_iam_binding" "bind_template_user" {
  certificate_authority_id = google_privateca_certificate_authority.intermediate_ca.certificate_authority_id
  role = "roles/privateca.templateUser"

  members = var.intermediate_ca_iam_members
}