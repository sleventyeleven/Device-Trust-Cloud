# CA Pool Module
# Creates a shared Enterprise-tier CA pool for both root and intermediate CAs

resource "google_privateca_ca_pool" "root_pool" {
  name = var.root_ca_pool_name
  tier = "ENTERPRISE"

  # Publishing options
  publishing_options {
    publish_ca_cert = var.enable_root_publishing
    publish_crl      = var.enable_root_publishing
  }

  # Enable Cloud Audit Logs
  enable_issue_cert_field_info = true
  enable_revocation_check = true

  description = "Root Certificate Authority pool for Device Trust"
}

resource "google_privateca_ca_pool" "ca_pool" {
  name = var.ca_pool_name
  tier = var.ca_pool_tier

  # Publishing options
  publishing_options {
    publish_ca_cert = var.enable_publishing
    publish_crl      = var.enable_publishing
  }

  # Enable Cloud Audit Logs
  enable_issue_cert_field_info = true
  enable_revocation_check = true

  description = "Certificate Authority pool for Device Trust"
}