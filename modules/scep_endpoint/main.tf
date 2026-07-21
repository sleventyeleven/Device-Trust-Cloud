# SCEP Endpoint Module
# Creates a secure SCEP endpoint with Cloud Load Balancing and ACME integration

# Allowlisted IPs for SCEP access
resource "google_compute_address" "scep_address" {
  name   = "${var.scep_endpoint_name}-address"
  region = var.region
}

# Load Balancer
resource "google_compute_target_tcp_proxy" "scep_proxy" {
  name            = "${var.scep_endpoint_name}-proxy"
  backend_service = google_compute_backend_service.scep_backend.id
}

# Health check
resource "google_compute_health_check" "scep_health_check" {
  name = "${var.scep_endpoint_name}-health-check"

  tcp_health_check {
    port = 80
  }
}

# Backend service
resource "google_compute_backend_service" "scep_backend" {
  name          = "${var.scep_endpoint_name}-backend"
  protocol      = "TCP"
  port_name     = "scep"
  health_checks = [google_compute_health_check.scep_health_check.id]

  backend {
    group = google_compute_instance_group.scep_instance_group.id
  }

  # Connection draining
  connection_draining_timeout_sec = var.connection_draining_timeout

  # Timeout
  timeout_sec = var.backend_timeout_sec
}

# Instance group
resource "google_compute_instance_group" "scep_instance_group" {
  name = "${var.scep_endpoint_name}-group"
  zone = var.zone

  named_port {
    name = "scep"
    port = var.scep_port
  }
}

# Compute Engine instance for SCEP endpoint
resource "google_compute_instance" "scep_instance" {
  name = "${var.scep_endpoint_name}-instance"
  zone = var.zone

  machine_type = var.machine_type

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2204-lts"
      size  = var.boot_disk_size
      type  = var.boot_disk_type
    }
  }

  network_interface {
    network    = var.network_name
    subnetwork = var.subnet_name
    access_config {
      # Ephemeral IP
    }
  }

  metadata = {
    startup-script = <<-EOT
      #!/bin/bash
      set -e

      # Install SCEP client
      apt-get update
      apt-get install -y scepclient || apt-get install -y scep

      # Configure SCEP
      cat > /etc/scep.conf <<EOF
      [scep]
      server = https://${google_compute_global_forwarding_rule.scep_forwarding_rule.ip_address}/scep
      challenge = simple
      CAcertificate = ${var.scep_ca_certificate}
      key = /etc/scep.key
      cert = /etc/scep.crt
      EOF

      # Start SCEP client
      nohup scepclient -d > /var/log/scep.log 2>&1 &
    EOT
  }

  service_account {
    email  = var.service_account_email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  tags = ["scep"]
}

# Network load balancer
resource "google_compute_global_forwarding_rule" "scep_forwarding_rule" {
  name                  = "${var.scep_endpoint_name}-forwarding-rule"
  load_balancing_scheme = "EXTERNAL"
  ip_protocol           = "TCP"
  port_range            = "80"
  ip_address            = google_compute_address.scep_address.address

  target = google_compute_target_tcp_proxy.scep_proxy.id

  description = "SCEP endpoint load balancer"
}

# Firewall rule for SCEP access
resource "google_compute_firewall" "scep_firewall" {
  name = "${var.scep_endpoint_name}-firewall"

  network = var.network_name

  allow {
    protocol = "tcp"
    ports    = ["80"]
  }

  source_ranges = var.scep_allowed_ips

  target_tags = ["scep"]

  description = "Firewall rule for SCEP endpoint access"
}

# IAM binding for SCEP endpoint
resource "google_compute_instance_iam_binding" "bind_scep" {
  instance_name = google_compute_instance.scep_instance.name
  zone          = var.zone
  role          = "roles/compute.instanceAdmin"

  members = var.scep_iam_members
}

# Autoscaler for the SCEP instance group
resource "google_compute_autoscaler" "scep_autoscaler" {
  name = "${var.scep_endpoint_name}-autoscaler"
  zone = var.zone

  target = google_compute_instance_group.scep_instance_group.id

  autoscaling_policy {
    max_replicas    = var.autoscale_max_instances
    min_replicas    = var.autoscale_min_instances
    cooldown_period = var.autoscale_cooldown_period

    cpu_utilization {
      target = 0.6
    }
  }
}
