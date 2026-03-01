output "root_ca_pool_id" {
  description = "ID of the root CA pool"
  value       = google_privateca_ca_pool.root_pool.id
}

output "root_ca_pool_name" {
  description = "Name of the root CA pool"
  value       = google_privateca_ca_pool.root_pool.name
}

output "ca_pool_id" {
  description = "ID of the CA pool"
  value       = google_privateca_ca_pool.ca_pool.id
}

output "ca_pool_name" {
  description = "Name of the CA pool"
  value       = google_privateca_ca_pool.ca_pool.name
}

output "root_ca_pool_location" {
  description = "Location of the root CA pool"
  value       = google_privateca_ca_pool.root_pool.location
}

output "ca_pool_location" {
  description = "Location of the CA pool"
  value       = google_privateca_ca_pool.ca_pool.location
}

output "root_ca_pool_issuer_certificate" {
  description = "Root CA pool issuer certificate"
  value       = google_privateca_ca_pool.root_pool.issuer_certificate
}

output "ca_pool_issuer_certificate" {
  description = "CA pool issuer certificate"
  value       = google_privateca_ca_pool.ca_pool.issuer_certificate
}