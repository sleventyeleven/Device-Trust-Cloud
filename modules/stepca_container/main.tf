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
    enroll_provisioner    = var.webhook_enroll_provisioner
    renew_provisioner     = var.webhook_renew_provisioner
    webhook_enabled       = var.enable_webhook
    webhook_url           = local.webhook_url
    cert_lifetime         = var.scep_cert_lifetime
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

# ---------------------------------------------------------------------------
# Optional: device-trust-webhook (per-device SCEP challenges), see
# webhook/README.md. Everything below only exists when enable_webhook is set.
# ---------------------------------------------------------------------------

locals {
  # step-ca only calls https webhook URLs. The webhook listens on the Docker
  # bridge address of the VM, which is how the step-ca container reaches the
  # host. step-ca trusts our own root and intermediate CAs for webhook servers,
  # so the webhook's certificate is simply issued from the intermediate CA.
  webhook_url = "https://172.17.0.1:8081/scep/challenge"
}

resource "tls_private_key" "webhook" {
  count     = var.enable_webhook ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "webhook" {
  count           = var.enable_webhook ? 1 : 0
  private_key_pem = tls_private_key.webhook[0].private_key_pem

  subject {
    common_name = "${var.stepca_instance_name}-webhook"
  }

  dns_names    = ["localhost"]
  ip_addresses = ["172.17.0.1"]
}

# Same permanent-audit-record caveat as the SCEP decrypter certificate above.
resource "random_id" "webhook_cert_suffix" {
  count       = var.enable_webhook ? 1 : 0
  byte_length = 4
  keepers = {
    csr = tls_cert_request.webhook[0].cert_request_pem
  }
}

resource "google_privateca_certificate" "webhook" {
  count                 = var.enable_webhook ? 1 : 0
  pool                  = var.ca_pool_name
  location              = var.location
  name                  = "${var.stepca_instance_name}-webhook-tls-${random_id.webhook_cert_suffix[0].hex}"
  lifetime              = "7776000s" # 90 days; the VM re-reads it every few minutes
  pem_csr               = tls_cert_request.webhook[0].cert_request_pem
  certificate_authority = var.intermediate_ca_name
}

resource "google_secret_manager_secret" "webhook_tls_cert" {
  count     = var.enable_webhook ? 1 : 0
  secret_id = "${var.stepca_instance_name}-dtw-tls-cert"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "webhook_tls_cert" {
  count  = var.enable_webhook ? 1 : 0
  secret = google_secret_manager_secret.webhook_tls_cert[0].id
  secret_data = join("\n", concat(
    [google_privateca_certificate.webhook[0].pem_certificate],
    google_privateca_certificate.webhook[0].pem_certificate_chain,
  ))
}

resource "google_secret_manager_secret" "webhook_tls_key" {
  count     = var.enable_webhook ? 1 : 0
  secret_id = "${var.stepca_instance_name}-dtw-tls-key"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "webhook_tls_key" {
  count       = var.enable_webhook ? 1 : 0
  secret      = google_secret_manager_secret.webhook_tls_key[0].id
  secret_data = tls_private_key.webhook[0].private_key_pem
}

# The device allowlist. Terraform writes the first version; an inventory sync
# job can add newer versions and the VM picks up the latest one.
resource "google_secret_manager_secret" "webhook_devices" {
  count     = var.enable_webhook ? 1 : 0
  secret_id = "${var.stepca_instance_name}-dtw-devices"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "webhook_devices" {
  count       = var.enable_webhook ? 1 : 0
  secret      = google_secret_manager_secret.webhook_devices[0].id
  secret_data = var.webhook_devices != "" ? var.webhook_devices : "# managed by terraform: add HOSTNAME,SERIAL lines\n"
}

resource "google_secret_manager_secret_iam_member" "webhook_accessor" {
  for_each = var.enable_webhook ? {
    tls_cert = google_secret_manager_secret.webhook_tls_cert[0].id
    tls_key  = google_secret_manager_secret.webhook_tls_key[0].id
    devices  = google_secret_manager_secret.webhook_devices[0].id
  } : {}

  secret_id = each.value
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.sa_stepca.email}"
}

# The webhook binary is too large for Secret Manager, so it is staged in a
# bucket the VM's service account can read.
resource "random_id" "webhook_bucket_suffix" {
  count       = var.enable_webhook ? 1 : 0
  byte_length = 4
}

resource "google_storage_bucket" "webhook" {
  count                       = var.enable_webhook ? 1 : 0
  name                        = "${var.stepca_instance_name}-dtw-${random_id.webhook_bucket_suffix[0].hex}"
  location                    = var.location
  uniform_bucket_level_access = true
  force_destroy               = true
}

resource "google_storage_bucket_object" "webhook_binary" {
  count  = var.enable_webhook ? 1 : 0
  name   = "device-trust-webhook"
  bucket = google_storage_bucket.webhook[0].name
  source = var.webhook_binary_path

  lifecycle {
    precondition {
      condition     = var.webhook_binary_path != "" && fileexists(var.webhook_binary_path)
      error_message = "enable_webhook needs webhook_binary_path to point at a built linux/amd64 device-trust-webhook binary (cd webhook && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o device-trust-webhook .)."
    }
  }
}

resource "google_storage_bucket_iam_member" "webhook_binary_reader" {
  count  = var.enable_webhook ? 1 : 0
  bucket = google_storage_bucket.webhook[0].name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.sa_stepca.email}"
}

# The pinned keys are the only record of which key each host enrolled with, so
# they live on their own small persistent disk.
resource "google_compute_disk" "webhook_data" {
  count = var.enable_webhook ? 1 : 0
  name  = "${var.stepca_instance_name}-dtw-data"
  type  = "pd-standard"
  size  = 1
  zone  = var.zone
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

locals {
  startup_head = <<-EOT
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
  EOT

  # The webhook is started before step-ca so it is ready for the first request.
  startup_webhook = var.enable_webhook ? templatefile("${path.module}/templates/webhook-setup.sh.tftpl", {
    bucket             = google_storage_bucket.webhook[0].name
    object             = google_storage_bucket_object.webhook_binary[0].name
    project_id         = var.project_id
    devices_secret     = google_secret_manager_secret.webhook_devices[0].secret_id
    tls_cert_secret    = google_secret_manager_secret.webhook_tls_cert[0].secret_id
    tls_key_secret     = google_secret_manager_secret.webhook_tls_key[0].secret_id
    enroll_provisioner = var.webhook_enroll_provisioner
    renew_provisioner  = var.webhook_renew_provisioner
  }) : ""

  startup_tail = <<-EOT

      docker run -d --name step-ca --restart unless-stopped \
        -p ${var.stepca_port}:${var.stepca_port} \
        -v /etc/stepca/config:/home/step/config \
        -v /etc/stepca/secrets:/home/step/secrets \
        ${var.stepca_container_image}
    EOT

  startup_script = "${local.startup_head}${local.startup_webhook}${local.startup_tail}"
}

resource "google_compute_instance" "stepca" {
  name         = var.stepca_instance_name
  zone         = var.zone
  machine_type = var.machine_type
  tags         = ["stepca"]

  # Attaching the webhook's data disk to an existing VM needs a stop/start.
  allow_stopping_for_update = true

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2204-lts"
    }
  }

  dynamic "attached_disk" {
    for_each = google_compute_disk.webhook_data
    content {
      source      = attached_disk.value.id
      device_name = "dtw-data"
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
    ca-json-secret-version         = google_secret_manager_secret_version.ca_json.name
    stepca-password-secret-version = google_secret_manager_secret_version.stepca_password.name

    # HCL keeps carriage returns, so a CRLF checkout (git autocrlf on Windows)
    # would leave "#!/bin/bash\r" and the script would not run. Strip them.
    startup-script = replace(local.startup_script, "\r", "")
  }

  depends_on = [
    google_secret_manager_secret_iam_member.ca_json_accessor,
    google_secret_manager_secret_version.ca_json,
    google_secret_manager_secret_iam_member.stepca_password_accessor,
    google_secret_manager_secret_version.stepca_password,
    google_secret_manager_secret_iam_member.webhook_accessor,
    google_secret_manager_secret_version.webhook_tls_cert,
    google_secret_manager_secret_version.webhook_tls_key,
    google_secret_manager_secret_version.webhook_devices,
    google_storage_bucket_iam_member.webhook_binary_reader,
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
