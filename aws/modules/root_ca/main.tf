# Root CA Module (AWS)
# A self-signed root Certificate Authority in AWS Private CA. Unlike Google
# Cloud CAS, AWS Private CA does not auto-chain a subordinate to its parent -
# the CA resource is created in a PENDING_CERTIFICATE state and has to be
# manually signed and activated, which is what the certificate + activation
# resources below do.
#
# usage_mode must stay GENERAL_PURPOSE (not SHORT_LIVED_CERTIFICATE) -
# Connector for SCEP only works with general-purpose CAs.

resource "aws_acmpca_certificate_authority" "root" {
  type       = "ROOT"
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

# Self-sign the root's own CSR - this is the "activation" step. Root CAs
# take no certificate_chain (there is nothing above them to chain to).
resource "aws_acmpca_certificate" "root" {
  certificate_authority_arn   = aws_acmpca_certificate_authority.root.arn
  certificate_signing_request = aws_acmpca_certificate_authority.root.certificate_signing_request
  signing_algorithm           = var.signing_algorithm
  template_arn                = "arn:aws:acm-pca:::template/RootCACertificate/V1"

  validity {
    type  = "YEARS"
    value = var.validity_years
  }
}

resource "aws_acmpca_certificate_authority_certificate" "root" {
  certificate_authority_arn = aws_acmpca_certificate_authority.root.arn
  certificate               = aws_acmpca_certificate.root.certificate
}
