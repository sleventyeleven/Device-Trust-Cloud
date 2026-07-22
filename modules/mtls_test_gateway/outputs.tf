output "mtls_gateway_ip" {
  description = "Public IP address of the mTLS test gateway"
  value       = google_compute_instance.mtls_gateway.network_interface[0].access_config[0].nat_ip
}

output "mtls_gateway_url" {
  description = "Convenience HTTPS URL of the mTLS test gateway"
  value       = "https://${google_compute_instance.mtls_gateway.network_interface[0].access_config[0].nat_ip}/"
}
