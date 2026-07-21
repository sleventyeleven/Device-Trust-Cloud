# Network Module
# Creates an isolated VPC with private subnets and VPC connector for Cloud Run

resource "google_compute_network" "vpc" {
  name                    = var.network_name
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"

  description = "VPC network for Device Trust PKI infrastructure"
}

resource "google_compute_subnetwork" "subnet" {
  name          = var.subnet_name
  ip_cidr_range = var.subnet_cidr_range
  region        = var.region
  network       = google_compute_network.vpc.id

  description = "Private subnet for Device Trust services"
}

# VPC connector for Cloud Run
resource "google_vpc_access_connector" "connector" {
  name                    = var.vpc_connector_name
  network                 = google_compute_network.vpc.id
  ip_cidr_range           = "10.8.0.0/28"
  region                  = var.region
  machine_type            = var.vpc_connector_machine_type
  min_instances           = var.vpc_connector_min_instances
  max_instances           = var.vpc_connector_max_instances
}