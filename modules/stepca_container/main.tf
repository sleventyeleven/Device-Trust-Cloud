# Step-ca Container Module
# Deploys step-ca (running its own TLS termination, required by the binary
# itself) as a Docker container on a Compute Engine VM. Cloud Run cannot host
# it: Cloud Run always terminates TLS at its edge and forwards plaintext HTTP
# internally, and step-ca has no option to disable its own TLS termination.

# Create service account for step-ca
resource "google_service_account" "sa_stepca" {
  account_id   = "${var.service_account_name}-stepca"
  display_name = "${var.service_account_display_name} - Step-ca"
}

# step-ca runs as a Registration Authority (RA) in front of the GCP-managed
# intermediate CA: CAS holds and uses the intermediate's private key, step-ca
# never does. SCEP's PKCS#7 envelope decryption still needs a locally-held
# keypair though, so we issue one as a leaf cert off the same intermediate CA.
resource "tls_private_key" "scep_decrypter" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "scep_decrypter" {
  private_key_pem = tls_private_key.scep_decrypter.private_key_pem

  subject {
    common_name = "${var.stepca_instance_name}-scep-decrypter"
  }
}

# google_privateca_certificate resources are permanent audit records in CAS -
# "destroying" one in Terraform doesn't actually delete it there, so recreating
# with the same name 409s. Suffix the name with an ID tied to the CSR so a
# fresh name is used automatically whenever the underlying key actually changes.
resource "random_id" "scep_decrypter_suffix" {
  byte_length = 4
  keepers = {
    csr = tls_cert_request.scep_decrypter.cert_request_pem
  }
}

resource "google_privateca_certificate" "scep_decrypter" {
  pool     = var.ca_pool_name
  location = var.location
  name     = "${var.stepca_instance_name}-scep-decrypter-${random_id.scep_decrypter_suffix.hex}"
  # 90 days: short-lived by design, and comfortably inside the intermediate
  # CA's actual remaining validity (its real lifetime is ~6 months, not the
  # 5 years its variable comment claims - a pre-existing bug, flagged
  # separately since fixing it would force-recreate the whole CA hierarchy).
  lifetime              = "7776000s"
  pem_csr               = tls_cert_request.scep_decrypter.cert_request_pem
  certificate_authority = var.intermediate_ca_name
}

# Shared secret SCEP clients present to enroll. Retrieve via the
# scep_challenge_password root output.
resource "random_password" "scep_challenge" {
  length  = 24
  special = false
}

locals {
  ca_json = templatefile("${path.module}/templates/ca.json.tftpl", {
    port                  = var.stepca_port
    dns_names_json        = jsonencode(var.stepca_domain != "" ? [var.stepca_domain] : ["localhost"])
    certificate_authority = var.intermediate_ca_resource_id
    scep_challenge        = random_password.scep_challenge.result
    decrypter_cert_b64    = base64encode(google_privateca_certificate.scep_decrypter.pem_certificate)
    decrypter_key_b64     = base64encode(tls_private_key.scep_decrypter.private_key_pem)
  })
}

# Secret Manager is how the VM's startup script pulls its config at boot
# (fetched via the metadata-server access token against the Secret Manager
# REST API - see the startup-script below).
resource "google_secret_manager_secret" "ca_json" {
  secret_id = "${var.stepca_instance_name}-ca-json"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "ca_json" {
  secret      = google_secret_manager_secret.ca_json.id
  secret_data = local.ca_json
}

resource "google_secret_manager_secret_iam_member" "ca_json_accessor" {
  secret_id = google_secret_manager_secret.ca_json.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.sa_stepca.email}"
}

# The stock image's entrypoint unconditionally passes --password-file to
# step-ca, even in cloudCAS RA mode where nothing is actually encrypted with
# it. Provide a placeholder so the container can start.
resource "random_password" "stepca_dummy_password" {
  length  = 32
  special = false
}

resource "google_secret_manager_secret" "stepca_password" {
  secret_id = "${var.stepca_instance_name}-password"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "stepca_password" {
  secret      = google_secret_manager_secret.stepca_password.id
  secret_data = random_password.stepca_dummy_password.result
}

resource "google_secret_manager_secret_iam_member" "stepca_password_accessor" {
  secret_id = google_secret_manager_secret.stepca_password.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.sa_stepca.email}"
}

# Allow Google's load balancer / health-check probes to reach the VM. The VM
# has no external IP, so this is the only way in.
resource "google_compute_firewall" "stepca_lb_health_check" {
  name    = "${var.stepca_instance_name}-lb-allow"
  network = var.network_name

  allow {
    protocol = "tcp"
    ports    = [tostring(var.stepca_port)]
  }

  # Google's documented health-check / LB source ranges
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
  target_tags   = ["stepca"]
}

# The VM has no external IP; allow SSH via Identity-Aware Proxy tunneling
# (IAP's fixed source range) for operational access, e.g. `gcloud compute ssh
# --tunnel-through-iap`. Requires the connecting user to also hold
# roles/iap.tunnelResourceAccessor, which is not granted here.
resource "google_compute_firewall" "stepca_iap_ssh" {
  name    = "${var.stepca_instance_name}-iap-ssh"
  network = var.network_name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["stepca"]
}

resource "google_compute_instance" "stepca" {
  name         = var.stepca_instance_name
  zone         = var.zone
  machine_type = var.machine_type
  tags         = ["stepca"]

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2204-lts"
    }
  }

  network_interface {
    network    = var.network_name
    subnetwork = var.subnet_name
    # No access_config: no external IP. The gateway LB reaches this VM over
    # internal VPC connectivity.
  }

  service_account {
    email  = google_service_account.sa_stepca.email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  metadata = {
    ca-json-secret-version       = google_secret_manager_secret_version.ca_json.name
    stepca-password-secret-version = google_secret_manager_secret_version.stepca_password.name

    startup-script = <<-EOT
      #!/bin/bash
      set -e

      apt-get update
      apt-get install -y docker.io jq

      mkdir -p /etc/stepca/config /etc/stepca/secrets

      TOKEN=$(curl -s -H "Metadata-Flavor: Google" \
        "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" \
        | jq -r .access_token)

      CA_JSON_SECRET=$(curl -s -H "Metadata-Flavor: Google" \
        "http://metadata.google.internal/computeMetadata/v1/instance/attributes/ca-json-secret-version")
      PASSWORD_SECRET=$(curl -s -H "Metadata-Flavor: Google" \
        "http://metadata.google.internal/computeMetadata/v1/instance/attributes/stepca-password-secret-version")

      curl -s -H "Authorization: Bearer $TOKEN" \
        "https://secretmanager.googleapis.com/v1/$${CA_JSON_SECRET}:access" \
        | jq -r .payload.data | base64 -d > /etc/stepca/config/ca.json

      curl -s -H "Authorization: Bearer $TOKEN" \
        "https://secretmanager.googleapis.com/v1/$${PASSWORD_SECRET}:access" \
        | jq -r .payload.data | base64 -d > /etc/stepca/secrets/password

      docker run -d --name step-ca --restart unless-stopped \
        -p ${var.stepca_port}:${var.stepca_port} \
        -v /etc/stepca/config:/home/step/config \
        -v /etc/stepca/secrets:/home/step/secrets \
        ${var.stepca_container_image}
    EOT
  }

  depends_on = [
    google_secret_manager_secret_iam_member.ca_json_accessor,
    google_secret_manager_secret_version.ca_json,
    google_secret_manager_secret_iam_member.stepca_password_accessor,
    google_secret_manager_secret_version.stepca_password,
  ]
}

resource "google_compute_instance_group" "stepca" {
  name      = "${var.stepca_instance_name}-group"
  zone      = var.zone
  instances = [google_compute_instance.stepca.self_link]

  named_port {
    name = "stepca-https"
    port = var.stepca_port
  }
}
