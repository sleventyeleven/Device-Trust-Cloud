# Step-ca Container Module
# Deploys step-ca as a Google Cloud Run service with SCEP provider and IAM permissions

# Create service account for step-ca
resource "google_service_account" "sa_stepca" {
  account_id   = "${var.service_account_name}-stepca"
  display_name = "${var.service_account_display_name} - Step-ca"
}

# Grant Cloud Run permissions to service account
resource "google_project_iam_binding" "cloud_run_service_agent" {
  project = var.project_id
  role    = "roles/run.serviceAgent"
  members = ["serviceAccount:${google_service_account.sa_stepca.email}"]
}

# Grant VPC connector permissions
resource "google_project_iam_binding" "vpc_connector_user" {
  project = var.project_id
  role    = "roles/vpcaccess.user"
  members = ["serviceAccount:${google_service_account.sa_stepca.email}"]
}

# Deploy step-ca as Cloud Run service
resource "google_cloud_run_service" "stepca" {
  name     = var.stepca_service_name
  location = var.location

  metadata {
    annotations = {
      "run.googleapis.com/launch-stage" = "BETA"
    }
  }

  template {
    metadata {
      annotations = merge(
        {
          "autoscaling.knative.dev/minScale" = tostring(var.min_instances)
          "autoscaling.knative.dev/maxScale" = tostring(var.max_instances)
        },
        var.vpc_connector_enabled ? {
          "run.googleapis.com/vpc-access-connector" = var.vpc_connector_name
          "run.googleapis.com/vpc-access-egress"     = "private-ranges-only"
        } : {}
      )
    }

    spec {
      service_account_name = google_service_account.sa_stepca.email
      containers {
        image = var.stepca_container_image

        # Environment variables
        env {
          name  = "STEPPATH"
          value = "/home/step"
        }

        env {
          name  = "CAROOT"
          value = "/home/step/certs"
        }

        env {
          name  = "ROLES"
          value = "root,intermediate"
        }

        env {
          name  = "FINGERPRINT"
          value = var.stepca_fingerprint
        }

        # Optional: Domain configuration for ACME
        dynamic "env" {
          for_each = var.stepca_domain != "" ? [
            {
              name  = "DOMAIN"
              value = var.stepca_domain
            },
            {
              name  = "DNS_NAMES"
              value = var.stepca_domain
            }
          ] : []
          content {
            name  = env.value.name
            value = env.value.value
          }
        }

        # Optional: Additional CA configuration
        dynamic "env" {
          for_each = var.stepca_ca_config != "" ? [
            {
              name  = "CA_CONFIG"
              value = var.stepca_ca_config
            }
          ] : []
          content {
            name  = env.value.name
            value = env.value.value
          }
        }

        # Resource limits
        resources {
          limits = {
            cpu    = "1000m"
            memory = "512Mi"
          }
        }

        # Port configuration
        ports {
          container_port = var.stepca_port
        }
      }

      # Container concurrency
      container_concurrency = 80

      # Request timeout
      timeout_seconds = 600
    }
  }

  # Traffic configuration
  traffic {
    percent         = 100
    latest_revision = true
  }

  autogenerate_revision_name = true
}

# Grant IAM roles for step-ca to access Private CA resources
# Note: These IAM bindings should be configured by the main Terraform configuration
# This module provides the service account that needs these permissions

# Expose step-ca with a managed domain (if configured)
resource "google_cloud_run_domain_mapping" "stepca_domain_mapping" {
  count = var.stepca_domain != "" && var.managed_domain_enabled ? 1 : 0

  location = var.location
  name     = var.stepca_domain

  metadata {
    namespace = var.project_id
  }

  spec {
    route_name = google_cloud_run_service.stepca.name
  }
}