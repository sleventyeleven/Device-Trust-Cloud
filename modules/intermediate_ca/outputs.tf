output "intermediate_ca_id" {
  description = "ID of the intermediate CA"
  value       = google_privateca_certificate_authority.intermediate_ca.id
}

output "intermediate_ca_name" {
  description = "Resource name of the intermediate CA"
  value       = google_privateca_certificate_authority.intermediate_ca.name
}

output "intermediate_ca_pem_certificate" {
  description = "PEM-encoded intermediate CA certificate"
  value       = google_privateca_certificate_authority.intermediate_ca.pem_ca_certificates[0]
  sensitive   = true
}

output "intermediate_ca_public_certificate" {
  description = "PEM-encoded public intermediate CA certificate"
  value       = google_privateca_certificate_authority.intermediate_ca.pem_ca_certificates[0]
}

output "intermediate_ca_issuing_ca" {
  description = "Issuing CA (parent root CA) resource name"
  value       = var.parent_ca_resource_name
}

output "intermediate_ca_pem_chain" {
  description = "Complete PEM-encoded certificate chain (intermediate + root)"
  value       = join("\n", [
    google_privateca_certificate_authority.intermediate_ca.pem_ca_certificates[0],
    var.root_ca_pem_certificate,
  ])
  sensitive = true
}
