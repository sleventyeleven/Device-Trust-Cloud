# Root CA Module
# Creates a self-signed root Certificate Authority with 10-year lifetime and deletion protection

resource "google_privateca_certificate_authority" "root_ca" {
  pool                     = var.root_ca_pool_name
  certificate_authority_id = var.root_ca_name
  location                 = var.location
  type                     = "SELF_SIGNED"

  # Key specification
  key_spec {
    algorithm = var.key_algorithm
  }

  # CA certificate lifetime (default: 10 years)
  lifetime = var.lifetime

  # Deletion protection for security
  deletion_protection = true

  # Publish CA certificate/CRLs to a Cloud Storage bucket (optional)
  gcs_bucket = var.root_ca_gcs_bucket != "" ? var.root_ca_gcs_bucket : null

  # CA configuration
  config {
    subject_config {
      subject {
        common_name  = var.root_ca_name
        organization = "Device Trust Infrastructure"
      }
    }

    x509_config {
      ca_options {
        is_ca = true
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
