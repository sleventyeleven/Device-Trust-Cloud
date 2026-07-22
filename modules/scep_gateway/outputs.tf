output "scep_gateway_ip" {
  description = "Static public IP of the SCEP gateway load balancer"
  value       = google_compute_global_address.gateway.address
}

output "scep_url" {
  description = "SCEP enrollment URL (only path publicly reachable through the gateway)"
  value       = "https://${google_compute_global_address.gateway.address}/scep/device-trust-scep"
}
