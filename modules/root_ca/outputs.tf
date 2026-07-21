output "root_ca_id" {
  description = "ID of the root CA"
  value       = google_privateca_certificate_authority.root_ca.id
}

output "root_ca_name" {
  description = "Resource name of the root CA (used as the parent reference for subordinate CAs)"
  value       = google_privateca_certificate_authority.root_ca.name
}

output "root_ca_pem_certificate" {
  description = "PEM-encoded root CA certificate"
  value       = google_privateca_certificate_authority.root_ca.pem_ca_certificates[0]
  sensitive   = true
}

output "root_ca_pem_certificate_chain" {
  description = "PEM-encoded root CA certificate chain"
  value       = google_privateca_certificate_authority.root_ca.pem_ca_certificates
  sensitive   = true
}

output "root_ca_public_certificate" {
  description = "PEM-encoded public root CA certificate"
  value       = google_privateca_certificate_authority.root_ca.pem_ca_certificates[0]
}
