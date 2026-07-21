output "stepca_service_name" {
  description = "Name of the Cloud Run service"
  value       = google_cloud_run_service.stepca.name
}

output "stepca_url" {
  description = "URL for step-ca service"
  value       = google_cloud_run_service.stepca.status[0].url
}

output "stepca_host" {
  description = "Host for step-ca service"
  value       = replace(google_cloud_run_service.stepca.status[0].url, "https://", "")
}

output "stepca_port" {
  description = "Port for step-ca service"
  value       = var.stepca_port
}

output "service_account_email" {
  description = "Email address of the step-ca service account"
  value       = google_service_account.sa_stepca.email
  sensitive   = true
}

output "stepca_domain_mapping_url" {
  description = "Domain mapping URL for step-ca"
  value       = var.managed_domain_enabled && var.stepca_domain != "" ? "https://${var.stepca_domain}" : ""
}

output "stepca_revision" {
  description = "Latest revision of the step-ca service"
  value       = google_cloud_run_service.stepca.status[0].latest_ready_revision_name
}
