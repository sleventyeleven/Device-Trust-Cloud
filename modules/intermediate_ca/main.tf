# Intermediate CA Module
# Creates a subordinate Certificate Authority (5-year lifetime) issued by the root CA

resource "google_privateca_certificate_authority" "intermediate_ca" {
  pool                     = var.ca_pool_name
  certificate_authority_id = var.intermediate_ca_name
  location                 = var.location
  type                     = "SUBORDINATE"

  # Reference the root CA as the issuer
  subordinate_config {
    certificate_authority = var.parent_ca_resource_name
  }

  # Key specification
  key_spec {
    algorithm = var.key_algorithm
  }

  # CA certificate lifetime (default: 5 years)
  lifetime = var.lifetime

  # Deletion protection for security
  deletion_protection = true

  # Subject
  config {
    subject_config {
      subject {
        common_name  = var.intermediate_ca_name
        organization = "Device Trust Infrastructure"
      }
    }

    x509_config {
      ca_options {
        is_ca                       = true
        zero_max_issuer_path_length = true
      }

      key_usage {
        base_key_usage {
          cert_sign = true
          crl_sign  = true
        }
        extended_key_usage {}
      }
    }
  }
}
