output "arn" {
  value = aws_acmpca_certificate_authority.intermediate.arn
}

output "certificate_pem" {
  description = "PEM-encoded intermediate CA certificate"
  value       = aws_acmpca_certificate.intermediate.certificate
}

output "activation_id" {
  description = "Used as a depends_on target so end-entity certs (SCEP connector use, mTLS gateway server cert) aren't issued before this CA is actually active"
  value       = aws_acmpca_certificate_authority_certificate.intermediate.id
}
