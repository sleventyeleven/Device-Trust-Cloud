# mTLS Test Gateway Module
# A simple nginx reverse proxy requiring TLS client certificate authentication
# (mTLS/ClientAuth), matching the pattern described at
# https://hackersvanguard.com/creating-a-simple-device-trust-gateway-using-device-certificates/ -
# used to verify enrolled device certificates actually work for ClientAuth,
# not just that they were issued. Deliberately a separate VM from step-ca's
# (which has no external IP by design) - this one is a public test target.

resource "google_service_account" "sa_mtls_gateway" {
  project      = var.project_id
  account_id   = "${var.mtls_gateway_name}-sa"
  display_name = "mTLS Test Gateway"
}

# Server TLS certificate, self-issued off the already-deployed intermediate
# CA (same pattern used for step-ca's SCEP decrypter cert and the SCEP
# gateway's own listener cert).
resource "tls_private_key" "server" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "server" {
  private_key_pem = tls_private_key.server.private_key_pem

  subject {
    common_name = var.mtls_gateway_name
  }
}

# google_privateca_certificate resources are permanent audit records in CAS -
# suffix the name with an ID tied to the CSR so regenerating it doesn't 409
# on a name collision (same pattern used twice already this session).
resource "random_id" "server_cert_suffix" {
  byte_length = 4
  keepers = {
    csr = tls_cert_request.server.cert_request_pem
  }
}

resource "google_privateca_certificate" "server" {
  project  = var.project_id
  pool     = var.ca_pool_name
  location = var.location
  name     = "${var.mtls_gateway_name}-tls-${random_id.server_cert_suffix.hex}"
  # 90 days: short-lived by design, and comfortably inside the intermediate
  # CA's actual remaining validity (see modules/stepca_container/main.tf note).
  lifetime              = "7776000s"
  pem_csr               = tls_cert_request.server.cert_request_pem
  certificate_authority = var.intermediate_ca_name
}

# The client CA trust bundle (root+intermediate) nginx validates device
# certificates against - public certificate data, delivered via instance
# metadata rather than Secret Manager since there's nothing sensitive in it.
locals {
  ca_bundle    = "${var.intermediate_ca_pem_certificate}\n${var.root_ca_pem_certificate}"
  server_cert  = google_privateca_certificate.server.pem_certificate
  nginx_conf   = <<-NGINXCONF
    log_format devicelog '$remote_addr - $remote_user [$time_local] '
                         '"$request" $status $body_bytes_sent '
                         'client_cert="$ssl_client_verify" '
                         'cn="$ssl_client_s_dn"';
    access_log /var/log/nginx/device_access.log devicelog;

    server {
        listen 443 ssl;
        server_name _;

        ssl_certificate /etc/nginx/certs/server.crt;
        ssl_certificate_key /etc/nginx/certs/server.key;
        ssl_client_certificate /etc/nginx/certs/ca-bundle.crt;
        ssl_verify_client on;

        location / {
            default_type text/plain;
            return 200 "mTLS authentication successful.\nVerify: $ssl_client_verify\nClient DN: $ssl_client_s_dn\n";
        }
    }
  NGINXCONF
}

# The server's private key is the only genuinely sensitive artifact here -
# delivered via Secret Manager, same mechanism used for step-ca's ca.json.
resource "google_secret_manager_secret" "server_key" {
  project   = var.project_id
  secret_id = "${var.mtls_gateway_name}-server-key"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "server_key" {
  secret      = google_secret_manager_secret.server_key.id
  secret_data = tls_private_key.server.private_key_pem
}

resource "google_secret_manager_secret_iam_member" "server_key_accessor" {
  secret_id = google_secret_manager_secret.server_key.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.sa_mtls_gateway.email}"
}

resource "google_compute_firewall" "mtls_gateway_https" {
  project = var.project_id
  name    = "${var.mtls_gateway_name}-https-allow"
  network = var.network_name

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }

  # Public test target by design - this is what the enrolled device cert
  # authenticates against directly from wherever the device is.
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["mtls-test-gateway"]
}

resource "google_compute_firewall" "mtls_gateway_iap_ssh" {
  project = var.project_id
  name    = "${var.mtls_gateway_name}-iap-ssh"
  network = var.network_name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["mtls-test-gateway"]
}

resource "google_compute_instance" "mtls_gateway" {
  project      = var.project_id
  name         = var.mtls_gateway_name
  zone         = var.zone
  machine_type = var.machine_type
  tags         = ["mtls-test-gateway"]

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2204-lts"
    }
  }

  network_interface {
    network    = var.network_name
    subnetwork = var.subnet_name
    access_config {
      # Ephemeral external IP - this VM is the public test target.
    }
  }

  service_account {
    email  = google_service_account.sa_mtls_gateway.email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  metadata = {
    ca-bundle                 = local.ca_bundle
    server-cert               = local.server_cert
    nginx-conf                = local.nginx_conf
    server-key-secret-version = google_secret_manager_secret_version.server_key.name

    startup-script = <<-EOT
      #!/bin/bash
      set -e

      apt-get update
      apt-get install -y docker.io jq

      mkdir -p /etc/nginx-test/certs /etc/nginx-test/conf.d

      curl -s -H "Metadata-Flavor: Google" \
        "http://metadata.google.internal/computeMetadata/v1/instance/attributes/ca-bundle" \
        > /etc/nginx-test/certs/ca-bundle.crt
      curl -s -H "Metadata-Flavor: Google" \
        "http://metadata.google.internal/computeMetadata/v1/instance/attributes/server-cert" \
        > /etc/nginx-test/certs/server.crt
      curl -s -H "Metadata-Flavor: Google" \
        "http://metadata.google.internal/computeMetadata/v1/instance/attributes/nginx-conf" \
        > /etc/nginx-test/conf.d/mtls.conf

      TOKEN=$(curl -s -H "Metadata-Flavor: Google" \
        "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" \
        | jq -r .access_token)

      SERVER_KEY_SECRET=$(curl -s -H "Metadata-Flavor: Google" \
        "http://metadata.google.internal/computeMetadata/v1/instance/attributes/server-key-secret-version")

      curl -s -H "Authorization: Bearer $TOKEN" \
        "https://secretmanager.googleapis.com/v1/$${SERVER_KEY_SECRET}:access" \
        | jq -r .payload.data | base64 -d > /etc/nginx-test/certs/server.key

      docker run -d --name mtls-test --restart unless-stopped \
        -p 443:443 \
        -v /etc/nginx-test/certs:/etc/nginx/certs:ro \
        -v /etc/nginx-test/conf.d:/etc/nginx/conf.d:ro \
        nginx:latest
    EOT
  }

  depends_on = [
    google_secret_manager_secret_iam_member.server_key_accessor,
    google_secret_manager_secret_version.server_key,
  ]
}
