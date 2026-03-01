output "root_ca_id" {
  description = "ID of the root CA"
  value       = google_privateca_certificate_authority.root_ca.id
}

output "root_ca_name" {
  description = "Name of the root CA"
  value       = google_privateca_certificate_authority.root_ca.name
}

output "root_ca_issuer_url" {
  description = "Issuer certificate URL for the root CA"
  value       = google_privateca_certificate_authority.root_ca.issuer_certificate_url
}

output "root_ca_issuer_certificate" {
  description = "Issuer certificate for the root CA"
  value       = google_privateca_certificate_authority.root_ca.issuer_certificate
  sensitive   = true
}

output "root_ca_certificate" {
  description = "Root CA certificate content"
  value       = google_privateca_certificate_authority.root_ca.certificates[0]
  sensitive   = true
}

output "root_ca_pem_certificate" {
  description = "PEM-encoded root CA certificate"
  value       = one(google_privateca_certificate_authority.root_ca.certificates)
  sensitive   = true
}

output "root_ca_private_key" {
  description = "Root CA private key (only if generated)"
  value       = null
  sensitive   = true
}

output "root_ca_pem_private_key" {
  description = "PEM-encoded root CA private key"
  value       = null
  sensitive   = true
}

output "root_ca_crl" {
  description = "Root CA CRL"
  value       = null
  sensitive   = true
}

output "root_ca_public_certificate" {
  description = "PEM-encoded public certificate"
  value       = one(google_privateca_certificate_authority.root_ca.certificates)
  sensitive   = false
}