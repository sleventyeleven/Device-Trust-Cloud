# Certificate Template Module
# Defines SCEP-compatible certificate template with proper extensions

resource "google_privateca_certificate_template" "scep_template" {
  location = var.location
  name = var.certificate_template_name
  description = var.certificate_template_description

  # Allow subject and subject alt names passthrough
  identity_constraints {
    allow_subject_alt_names_passthrough = true
    allow_subject_passthrough = true
  }

  # Predefined key usage
  predefined_values {
    key_usage {
      base_key_usage {
        digital_signature = true
        key_encipherment = true
      }
      extended_key_usage {
        server_auth = true
        client_auth = true
        code_signing = true
        email_protection = true
      }
    }

    # Predefined valid idp_ids
    valid_idp_ids = var.valid_idp_ids
  }

  # X.509 extensions
  x509_config {
    subject_config {
      country_name = var.default_country
      organization_name = var.default_organization
      common_name = var.default_common_name
    }

    key_usage_config {
      base_key_usage {
        digital_signature = true
        content_commitment = false
        key_encipherment = true
        data_encipherment = false
        key_agreement = false
        key_cert_sign = false
        crl_sign = false
        encipher_only = false
        decipher_only = false
      }
      extended_key_usage {
        server_auth = true
        client_auth = true
        code_signing = true
        email_protection = true
        smart_card_logon = true
        ocsp_signing = true
        time_stamping = false
        microsoft_sgc = false
        netscape_server_gated_crypto = false
      }
      unknown_critical_key_usage_extensions = var.unknown_critical_key_usage_extensions
    }

    aia_config {
      ca_issuers_uri = true
      ocsp_uri = true
    }

    name_constraints_config {
      permitted_names = var.permitted_dns_names
      excluded_names = var.excluded_dns_names
    }

    # Custom extensions
    custom_extensions {
      id = "1.3.6.1.5.5.7.1.1"  # Authority Information Access
      value = var.authority_info_access
      critical = false
    }
  }

  # Policy criteria
  policy_criteria {
    allowed_key_usages {
      base_key_usage {
        digital_signature = true
        key_encipherment = true
      }
      extended_key_usage {
        client_auth = true
        server_auth = true
        code_signing = true
      }
    }
  }

  # Key parameters
  key_params {
    algorithm = var.key_algorithm
    key_size = var.key_size
  }

  # Subject
  subject {
    common_name = var.common_name
    organization = var.organization
    country = var.country
    organizational_unit = var.organizational_unit
    locality = var.locality
    province = var.province
    street_address = var.street_address
    postal_code = var.postal_code
    dns_names = var.dns_names
    email_addresses = var.email_addresses
    ip_addresses = var.ip_addresses
    uris = var.uris
  }
}