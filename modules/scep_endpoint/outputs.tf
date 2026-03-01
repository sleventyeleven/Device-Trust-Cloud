output "scep_endpoint_name" {
  description = "Name of the SCEP endpoint"
  value       = var.scep_endpoint_name
}

output "scep_url" {
  description = "URL for SCEP endpoint"
  value       = "https://${google_compute_global_forwarding_rule.scep_forwarding_rule.ip_address}"
}

output "scep_ip_address" {
  description = "IP address of the SCEP endpoint"
  value       = google_compute_global_forwarding_rule.scep_forwarding_rule.ip_address
}

output "scep_firewall_name" {
  description = "Name of the firewall rule"
  value       = google_compute_firewall.scep_firewall.name
}

output "scep_instance_group" {
  description = "Name of the instance group"
  value       = google_compute_instance_group.scep_instance_group.name
}

output "scep_instance" {
  description = "Name of the SCEP instance"
  value       = google_compute_instance.scep_instance.name
}

output "scep_target_proxy" {
  description = "Name of the target TCP proxy"
  value       = google_compute_target_tcp_proxy.scep_proxy.name
}

output "scep_backend_service" {
  description = "Name of the backend service"
  value       = google_compute_backend_service.scep_backend.name
}