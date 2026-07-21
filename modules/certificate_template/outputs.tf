output "certificate_template_id" {
  description = "ID of the certificate template"
  value       = google_privateca_certificate_template.scep_template.id
}

output "certificate_template_name" {
  description = "Name of the certificate template"
  value       = google_privateca_certificate_template.scep_template.name
}

output "certificate_template_location" {
  description = "Location of the certificate template"
  value       = google_privateca_certificate_template.scep_template.location
}

output "certificate_template_description" {
  description = "Description of the certificate template"
  value       = google_privateca_certificate_template.scep_template.description
}
