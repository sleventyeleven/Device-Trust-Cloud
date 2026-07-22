# SCEP Gateway Module
# Public-facing external HTTPS load balancer in front of the Cloud Run
# step-ca service, restricted to only the /scep/* path via URL map routing.
# Everything else (step-ca's ACME/admin/API surface) is not reachable through
# this gateway.

resource "google_compute_global_address" "gateway" {
  name = "${var.scep_gateway_name}-ip"
}

# step-ca terminates its own TLS (required by the binary itself - it cannot
# be disabled) and runs on a VM behind this backend. The LB terminates the
# client-facing hop (below) and re-encrypts for this backend hop; GCP's
# backend-HTTPS re-encryption doesn't validate the backend's certificate
# chain, so step-ca's own (possibly self-signed) listener cert is fine here -
# it's never seen by end clients, who only ever validate the gateway's own
# cert further down.
resource "google_compute_health_check" "stepca" {
  name = "${var.scep_gateway_name}-health-check"

  https_health_check {
    port         = var.stepca_port
    request_path = "/health"
  }
}

resource "google_compute_backend_service" "stepca" {
  name          = "${var.scep_gateway_name}-backend"
  protocol      = "HTTPS"
  port_name     = "stepca-https"
  health_checks = [google_compute_health_check.stepca.id]

  backend {
    group = var.stepca_instance_group_id
  }
}

# TLS certificate for the gateway's HTTPS listener, self-issued off the
# already-deployed intermediate CA. Avoids needing a public domain + Google-
# managed certificate: the install scripts install our root CA into the OS
# trust store before calling scepclient, so this is already trusted.
resource "tls_private_key" "gateway" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "gateway" {
  private_key_pem = tls_private_key.gateway.private_key_pem

  subject {
    common_name = "${var.scep_gateway_name}"
  }

  ip_addresses = [google_compute_global_address.gateway.address]
}

# google_privateca_certificate resources are permanent audit records in CAS -
# suffix the name with an ID tied to the CSR so regenerating it doesn't 409
# on a name collision (same pattern as the stepca module's SCEP decrypter cert).
resource "random_id" "gateway_cert_suffix" {
  byte_length = 4
  keepers = {
    csr = tls_cert_request.gateway.cert_request_pem
  }
}

resource "google_privateca_certificate" "gateway" {
  pool     = var.ca_pool_name
  location = var.location
  name     = "${var.scep_gateway_name}-tls-${random_id.gateway_cert_suffix.hex}"
  # 90 days: short-lived by design, and comfortably inside the intermediate
  # CA's actual remaining validity (see modules/stepca_container/main.tf note).
  lifetime              = "7776000s"
  pem_csr               = tls_cert_request.gateway.cert_request_pem
  certificate_authority = var.intermediate_ca_name
}

resource "google_compute_ssl_certificate" "gateway" {
  name_prefix = "${var.scep_gateway_name}-"
  private_key = tls_private_key.gateway.private_key_pem
  certificate = join("\n", concat(
    [google_privateca_certificate.gateway.pem_certificate],
    google_privateca_certificate.gateway.pem_certificate_chain,
  ))

  lifecycle {
    create_before_destroy = true
  }
}

# Deny-by-default backend: an empty GCS bucket 404s any request, giving a
# clean "deny" target for every path other than /scep/* with no app to run.
resource "random_id" "deny_bucket_suffix" {
  byte_length = 4
}

resource "google_storage_bucket" "deny_all" {
  name                        = "${var.scep_gateway_name}-deny-${random_id.deny_bucket_suffix.hex}"
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = true
}

resource "google_compute_backend_bucket" "deny_all" {
  name        = "${var.scep_gateway_name}-deny"
  bucket_name = google_storage_bucket.deny_all.name
}

resource "google_compute_url_map" "https" {
  name            = "${var.scep_gateway_name}-url-map"
  default_service = google_compute_backend_bucket.deny_all.id

  host_rule {
    hosts        = ["*"]
    path_matcher = "scep"
  }

  path_matcher {
    name            = "scep"
    default_service = google_compute_backend_bucket.deny_all.id

    path_rule {
      paths   = ["/scep/*"]
      service = google_compute_backend_service.stepca.id
    }
  }
}

resource "google_compute_target_https_proxy" "gateway" {
  name             = "${var.scep_gateway_name}-https-proxy"
  url_map          = google_compute_url_map.https.id
  ssl_certificates = [google_compute_ssl_certificate.gateway.id]
}

resource "google_compute_global_forwarding_rule" "https" {
  name                  = "${var.scep_gateway_name}-https"
  load_balancing_scheme = "EXTERNAL"
  ip_protocol           = "TCP"
  port_range            = "443"
  ip_address            = google_compute_global_address.gateway.address
  target                = google_compute_target_https_proxy.gateway.id
}

# Plain HTTP -> HTTPS redirect on port 80, same IP
resource "google_compute_url_map" "http_redirect" {
  name = "${var.scep_gateway_name}-http-redirect"

  default_url_redirect {
    https_redirect = true
    strip_query    = false
  }
}

resource "google_compute_target_http_proxy" "redirect" {
  name    = "${var.scep_gateway_name}-http-proxy"
  url_map = google_compute_url_map.http_redirect.id
}

resource "google_compute_global_forwarding_rule" "http" {
  name                  = "${var.scep_gateway_name}-http"
  load_balancing_scheme = "EXTERNAL"
  ip_protocol           = "TCP"
  port_range            = "80"
  ip_address            = google_compute_global_address.gateway.address
  target                = google_compute_target_http_proxy.redirect.id
}
