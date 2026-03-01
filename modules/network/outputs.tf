output "vpc_self_link" {
  description = "Self-link of the VPC network"
  value       = google_compute_network.vpc.self_link
}

output "subnet_self_link" {
  description = "Self-link of the subnet"
  value       = google_compute_subnet.subnet.self_link
}

output "subnet_id" {
  description = "ID of the subnet"
  value       = google_compute_subnet.subnet.id
}

output "vpc_connector_self_link" {
  description = "Self-link of the VPC connector"
  value       = google_vpc_access_connector.connector.self_link
}

output "vpc_connector_ip_range" {
  description = "IP CIDR range used by the VPC connector"
  value       = google_vpc_access_connector.connector.ip_cidr_range
}

output "network_name" {
  description = "Name of the network"
  value       = google_compute_network.vpc.name
}