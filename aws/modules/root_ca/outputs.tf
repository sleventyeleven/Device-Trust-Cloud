output "arn" {
  value = aws_acmpca_certificate_authority.root.arn
}

output "certificate_pem" {
  description = "PEM-encoded root CA certificate"
  value       = aws_acmpca_certificate.root.certificate
}

output "activation_id" {
  description = "Used as a depends_on target so the intermediate CA isn't signed before the root is actually active"
  value       = aws_acmpca_certificate_authority_certificate.root.id
}
