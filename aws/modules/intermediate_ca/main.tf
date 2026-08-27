# Intermediate CA Module (AWS)
# A subordinate Certificate Authority signed by the root CA. Unlike Google
# Cloud CAS's subordinate_config (which auto-chains a subordinate to its
# parent), AWS Private CA requires manually taking the subordinate's own
# CSR, signing it with the root CA via aws_acmpca_certificate, and then
# installing the signed certificate plus the full chain back onto the
# subordinate to activate it.

resource "aws_acmpca_certificate_authority" "intermediate" {
  type       = "SUBORDINATE"
  usage_mode = "GENERAL_PURPOSE"

  permanent_deletion_time_in_days = var.permanent_deletion_time_in_days

  certificate_authority_configuration {
    key_algorithm     = var.key_algorithm
    signing_algorithm = var.signing_algorithm

    subject {
      common_name  = var.common_name
      organization = var.organization
    }
  }

  tags = var.tags
}

resource "aws_acmpca_certificate" "intermediate" {
  certificate_authority_arn   = var.root_ca_arn
  certificate_signing_request = aws_acmpca_certificate_authority.intermediate.certificate_signing_request
  signing_algorithm           = var.signing_algorithm
  template_arn                = "arn:aws:acm-pca:::template/SubordinateCACertificate_PathLen0/V1"

  validity {
    type  = "YEARS"
    value = var.validity_years
  }
}

resource "aws_acmpca_certificate_authority_certificate" "intermediate" {
  certificate_authority_arn = aws_acmpca_certificate_authority.intermediate.arn
  certificate               = aws_acmpca_certificate.intermediate.certificate
  # certificate_chain is the chain ABOVE this CA (just the root, in this
  # two-tier hierarchy) - it must not also include the intermediate's own
  # certificate, which is already supplied separately via `certificate`.
  certificate_chain = var.root_ca_certificate_pem
}
