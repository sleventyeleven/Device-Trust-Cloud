resource "google_privateca_ca_pool" "root_pool" {
  name     = "root-ca-pool"
  location = "us-central1"
  tier     = "ENTERPRISE"
  publishing_options {
    publish_ca_cert = true
    publish_crl     = true
  }
}

resource "google_privateca_ca_pool" "devicetrust_pool" {
  name     = "devicetrust-pool"
  location = "us-central1"
  tier     = "ENTERPRISE"
  publishing_options {
    publish_ca_cert = true
    publish_crl     = true
  }
}

resource "google_privateca_certificate_authority" "root_ca" {
  pool                                   = google_privateca_ca_pool.root_pool.name
  certificate_authority_id               = "Lab-ca-root"
  location                               = "us-central1"
  deletion_protection                    = false
  ignore_active_certificates_on_deletion = true
  config {
    subject_config {
      subject {
        organization = "Lab"
        common_name  = "Lab-ca-root"
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
        extended_key_usage {
        }
      }
    }
  }
  key_spec {
    algorithm = "RSA_PKCS1_4096_SHA256"
  }
  // valid for 10 years
  lifetime = "${10 * 365 * 24 * 3600}s"
}

resource "google_privateca_certificate_authority" "sub_ca" {
  pool                     = google_privateca_ca_pool.devicetrust_pool.name
  certificate_authority_id = "Lab-ca-devicetrust"
  location                 = "us-central1"
  deletion_protection      = false
  subordinate_config {
    certificate_authority = google_privateca_certificate_authority.root_ca.name
  }
  config {
    subject_config {
      subject {
        organization = "Lab"
        common_name  = "Lab-ca-devicetrust"
      }
    }
    x509_config {
      ca_options {
        is_ca                  = true
        max_issuer_path_length = 1
      }
      key_usage {
        base_key_usage {
          cert_sign = true
          crl_sign  = true
        }
        extended_key_usage {
        }
      }
    }
  }
  // valid for 5 years
  lifetime = "${5 * 365 * 24 * 3600}s"
  key_spec {
    algorithm = "RSA_PKCS1_2048_SHA256"
  }
  type = "SUBORDINATE"
}

resource "google_privateca_certificate_template" "devicetrust_ca_template" {
  location    = "us-central1"
  name        = "devicetrust-ca-template"
  description = "A certificate template to get standard devicetrust cert"

  identity_constraints {
    allow_subject_alt_names_passthrough = true
    allow_subject_passthrough           = true

  }

  passthrough_extensions {
    additional_extensions {
      object_id_path = [1, 6]
    }

    known_extensions = ["EXTENDED_KEY_USAGE"]
  }

  predefined_values {
    additional_extensions {
      object_id {
        object_id_path = [1, 6]
      }

      value    = "c3RyaW5nCg=="
      critical = true
    }

    aia_ocsp_servers = ["string"]

    ca_options {
      is_ca                  = true
      max_issuer_path_length = 0
    }

    key_usage {
      base_key_usage {
        cert_sign          = true
        crl_sign           = true
      }

      extended_key_usage {
      }
    }

    policy_ids {
      object_id_path = [1, 6]
    }
  }
}

resource "google_service_account" "sa_stepca" {
  project      = module.base_info.project_id
  account_id   = "sa-stepca"
  display_name = "step-ca service account identity for server compute"
}

resource "google_privateca_certificate_template_iam_member" "member" {
  certificate_template = google_privateca_certificate_template.devicetrust_ca_template.id
  role                 = "roles/privateca.templateUser"
  member               = "serviceAccount:${google_service_account.sa_stepca.email}"
}
