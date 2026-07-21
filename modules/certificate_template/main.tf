# Certificate Template Module
# Defines a SCEP-compatible certificate template with client/server auth key usage

resource "google_privateca_certificate_template" "scep_template" {
  location    = var.location
  name        = var.certificate_template_name
  description = var.certificate_template_description

  maximum_lifetime = var.maximum_lifetime

  # Allow subject and subject alt names passthrough from the certificate request
  identity_constraints {
    allow_subject_alt_names_passthrough = true
    allow_subject_passthrough           = true
  }

  # Predefined X.509 values applied to all certificates issued from this template
  predefined_values {
    key_usage {
      base_key_usage {
        digital_signature = true
        key_encipherment  = true
      }
      extended_key_usage {
        server_auth      = true
        client_auth      = true
        code_signing     = true
        email_protection = true
      }
    }
  }
}
