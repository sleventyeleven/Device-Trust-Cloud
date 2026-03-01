output "intermediate_ca_id" {
  description = "ID of the intermediate CA"
  value       = google_privateca_certificate_authority.intermediate_ca.id
}

output "intermediate_ca_name" {
  description = "Name of the intermediate CA"
  value       = google_privateca_certificate_authority.intermediate_ca.name
}

output "intermediate_ca_issuer_url" {
  description = "Issuer certificate URL for the intermediate CA"
  value       = google_privateca_certificate_authority.intermediate_ca.issuer_certificate_url
}

output "intermediate_ca_issuer_certificate" {
  description = "Issuer certificate for the intermediate CA"
  value       = google_privateca_certificate_authority.intermediate_ca.issuer_certificate
  sensitive   = true
}

output "intermediate_ca_certificate" {
  description = "Intermediate CA certificate content"
  value       = google_privateca_certificate_authority.intermediate_ca.certificates[0]
  sensitive   = true
}

output "intermediate_ca_pem_certificate" {
  description = "PEM-encoded intermediate CA certificate"
  value       = one(google_privateca_certificate_authority.intermediate_ca.certificates)
  sensitive   = true
}

output "intermediate_ca_pem_private_key" {
  description = "PEM-encoded intermediate CA private key"
  value       = null
  sensitive   = true
}

output "intermediate_ca_public_certificate" {
  description = "PEM-encoded public certificate"
  value       = one(google_privateca_certificate_authority.intermediate_ca.certificates)
  sensitive   = false
}

output "intermediate_ca_issuing_ca" {
  description = "Issuing CA (parent root CA)"
  value       = google_privateca_certificate_authority.root_ca.name
}

output "intermediate_ca_pem_chain" {
  description = "Complete PEM-encoded certificate chain (root + intermediate)"
  value       = join("\n", [
    one(google_privateca_certificate_authority.root_ca.certificates),
    one(google_privateca_certificate_authority.intermediate_ca.certificates)
  ])
  sensitive   = true
}

output "intermediate_ca_public_chain" {
  description = "Complete PEM-encoded public certificate chain"
  value       = join("\n", [
    one(google_privateca_certificate_authority.root_ca.certificates),
    one(google_privateca_certificate_authority.intermediate_ca.certificates)
  ])
  sensitive   = false
}