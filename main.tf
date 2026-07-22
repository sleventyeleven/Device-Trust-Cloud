# Device Trust PKI Infrastructure
# Main Terraform configuration that orchestrates all modules

# Enable Terraform Cloud logging
terraform {
  backend "gcs" {
    bucket  = "device-trust-terraform-state"
    prefix  = "terraform-state"
  }
}

# Enable the GCP APIs this configuration depends on before creating any resources
resource "google_project_service" "apis" {
  for_each = toset(var.gcp_apis_to_enable)

  project = var.project_id
  service = each.value

  disable_dependent_services = false
  disable_on_destroy         = false
}

# Import the network module
module "network" {
  source = "./modules/network"

  depends_on = [google_project_service.apis]

  network_name      = var.network_name
  subnet_cidr_range = var.subnet_cidr_range
  subnet_name       = var.subnet_name
  region            = var.region
}

# Import the CA pool module
module "ca_pool" {
  source = "./modules/ca_pool"

  depends_on = [google_project_service.apis]

  root_ca_pool_name  = var.root_ca_pool_name
  ca_pool_name       = var.ca_pool_name
  ca_pool_tier       = var.ca_pool_tier
  enable_root_publishing = var.enable_root_publishing
  enable_publishing  = var.enable_publishing
  location           = var.location

  # IAM on Private CA is granted at the CA pool level. step-ca's cloudCAS
  # config only ever signs against the intermediate CA, never the root, so
  # the root pool intentionally gets no standing access here - it should
  # only ever be touched manually to sign a new intermediate every few years.
  ca_pool_iam_members = concat(["serviceAccount:${module.stepca.service_account_email}"], var.stepca_iam_members)
}

# Import the root CA module
module "root_ca" {
  source = "./modules/root_ca"

  depends_on = [google_project_service.apis]

  root_ca_name         = var.root_ca_name
  root_ca_pool_name    = module.ca_pool.root_ca_pool_name
  key_algorithm        = var.root_ca_key_algorithm
  lifetime             = var.root_ca_lifetime
  root_ca_gcs_bucket   = var.root_ca_gcs_bucket
  location             = var.location
}

# Import the intermediate CA module
module "intermediate_ca" {
  source = "./modules/intermediate_ca"

  depends_on = [google_project_service.apis]

  intermediate_ca_name    = var.intermediate_ca_name
  ca_pool_name            = module.ca_pool.ca_pool_name
  parent_ca_resource_name = module.root_ca.root_ca_name
  root_ca_pem_certificate = module.root_ca.root_ca_pem_certificate
  key_algorithm           = var.intermediate_ca_key_algorithm
  lifetime                = var.intermediate_ca_lifetime
  location                = var.location
}

# Import the certificate template module
module "certificate_template" {
  source = "./modules/certificate_template"

  depends_on = [google_project_service.apis]

  certificate_template_name         = var.certificate_template_name
  certificate_template_description  = var.certificate_template_description
  location                          = var.location

  certificate_template_iam_members = concat(["serviceAccount:${module.stepca.service_account_email}"], var.stepca_iam_members)
}

# Import the step-ca container module (Docker on a Compute Engine VM - step-ca
# terminates its own TLS, which Cloud Run cannot accommodate)
module "stepca" {
  source = "./modules/stepca_container"

  depends_on = [google_project_service.apis]

  service_account_name         = var.service_account_name
  service_account_display_name = var.service_account_display_name
  stepca_instance_name         = var.stepca_instance_name
  stepca_container_image       = var.stepca_container_image
  stepca_port                  = var.stepca_port
  stepca_domain                = var.stepca_domain
  machine_type                 = var.machine_type
  zone                         = var.zone
  network_name                 = module.network.network_name
  subnet_name                  = module.network.subnet_name
  project_id                   = var.project_id
  location                     = var.location

  ca_pool_name                = module.ca_pool.ca_pool_name
  intermediate_ca_name        = var.intermediate_ca_name
  intermediate_ca_resource_id = module.intermediate_ca.intermediate_ca_id
  ca_pool_iam_binding_ids     = module.ca_pool.ca_pool_iam_binding_ids
}

# Import the SCEP gateway module: path-restricted LB in front of the
# step-ca VM (only /scep/* is publicly reachable)
module "scep_gateway" {
  source = "./modules/scep_gateway"

  depends_on = [google_project_service.apis]

  scep_gateway_name        = var.scep_gateway_name
  stepca_instance_group_id = module.stepca.instance_group_id
  stepca_port              = module.stepca.stepca_port
  ca_pool_name             = module.ca_pool.ca_pool_name
  intermediate_ca_name     = var.intermediate_ca_name
  location                 = var.location
  region                   = var.region
}

# Optional: simple nginx mTLS test gateway - a public test target that
# requires TLS ClientAuth, used to verify enrolled device certs actually
# work for ClientAuth (not just that they were issued). Deliberately a
# separate VM from step-ca's (which has no external IP by design).
module "mtls_test_gateway" {
  source = "./modules/mtls_test_gateway"
  count  = var.enable_mtls_test_gateway ? 1 : 0

  depends_on = [google_project_service.apis]

  project_id                      = var.project_id
  mtls_gateway_name               = var.mtls_gateway_name
  ca_pool_name                    = module.ca_pool.ca_pool_name
  intermediate_ca_name            = var.intermediate_ca_name
  root_ca_pem_certificate         = module.root_ca.root_ca_pem_certificate
  intermediate_ca_pem_certificate = module.intermediate_ca.intermediate_ca_pem_certificate
  machine_type                    = var.mtls_gateway_machine_type
  zone                            = var.zone
  network_name                    = module.network.network_name
  subnet_name                     = module.network.subnet_name
  location                        = var.location
}

# Optional: DNS validation for ACME
resource "google_dns_managed_zone" "validation_zone" {
  count = var.acme_validation_enabled ? 1 : 0

  depends_on = [google_project_service.apis]

  name = "${var.project_id}-validation-zone"
  dns_name = var.acme_dns_zone_name
  description = "DNS zone for ACME challenge validation"
}

resource "google_dns_record_set" "acme_validation" {
  count = var.acme_validation_enabled ? 1 : 0

  managed_zone = google_dns_managed_zone.validation_zone[0].name
  name = "${var.acme_challenge_token}.${google_dns_managed_zone.validation_zone[0].dns_name}"
  type = "CNAME"
  ttl  = var.acme_validation_ttl
  rrdatas = [module.scep_gateway.scep_gateway_ip]
}
