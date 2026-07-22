output "stepca_instance_name" {
  description = "Name of the step-ca VM"
  value       = google_compute_instance.stepca.name
}

output "instance_group_id" {
  description = "ID of the (unmanaged) instance group containing the step-ca VM, for the gateway's backend service"
  value       = google_compute_instance_group.stepca.id
}

output "stepca_port" {
  description = "Port on which step-ca listens"
  value       = var.stepca_port
}

output "service_account_email" {
  description = "Email address of the step-ca service account"
  value       = google_service_account.sa_stepca.email
  sensitive   = true
}

output "scep_challenge_password" {
  description = "Shared secret SCEP clients must present to enroll"
  value       = random_password.scep_challenge.result
  sensitive   = true
}
