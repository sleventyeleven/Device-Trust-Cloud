# Device Trust PKI Infrastructure
# Main Terraform configuration that orchestrates all modules

# Enable Terraform Cloud logging
terraform {
  backend "gcs" {
    bucket  = "device-trust-terraform-state"
    prefix  = "terraform-state"
  }
}

# Import the network module
module "network" {
  source = "./modules/network"

  network_name           = var.network_name
  subnet_cidr_range      = var.subnet_cidr_range
  subnet_name            = var.subnet_name
  vpc_connector_name     = var.vpc_connector_name
  vpc_connector_min_instances = var.vpc_connector_min_instances
  vpc_connector_max_instances = var.vpc_connector_max_instances
  vpc_connector_machine_type = var.vpc_connector_machine_type
  region                 = var.region
}

# Import the CA pool module
module "ca_pool" {
  source = "./modules/ca_pool"

  root_ca_pool_name  = var.root_ca_pool_name
  ca_pool_name       = var.ca_pool_name
  ca_pool_tier       = var.ca_pool_tier
  enable_root_publishing = var.enable_root_publishing
  enable_publishing  = var.enable_publishing
  location           = var.location

  # IAM on Private CA is granted at the CA pool level; step-ca is the consumer that issues certificates
  root_ca_pool_iam_members = concat(["serviceAccount:${module.stepca.service_account_email}"], var.stepca_iam_members)
  ca_pool_iam_members      = concat(["serviceAccount:${module.stepca.service_account_email}"], var.stepca_iam_members)
}

# Import the root CA module
module "root_ca" {
  source = "./modules/root_ca"

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

  certificate_template_name         = var.certificate_template_name
  certificate_template_description  = var.certificate_template_description
  location                          = var.location
}

# Import the step-ca container module
module "stepca" {
  source = "./modules/stepca_container"

  service_account_name            = var.service_account_name
  service_account_display_name    = var.service_account_display_name
  stepca_service_name             = var.stepca_service_name
  stepca_container_image          = var.stepca_container_image
  stepca_port                     = var.stepca_port
  stepca_fingerprint              = var.stepca_fingerprint
  stepca_domain                   = var.stepca_domain
  stepca_ca_config                = var.stepca_ca_config
  stepca_grace_period_days        = var.stepca_grace_period_days
  min_instances                   = var.min_instances
  max_instances                   = var.max_instances
  managed_domain_enabled          = var.managed_domain_enabled
  vpc_connector_enabled           = var.vpc_connector_enabled
  vpc_connector_name              = var.vpc_connector_name
  project_id                      = var.project_id
  location                        = var.location
}

# Import the SCEP endpoint module
module "scep_endpoint" {
  source = "./modules/scep_endpoint"

  scep_endpoint_name             = var.scep_endpoint_name
  scep_port                      = var.scep_port
  scep_ca_certificate            = module.intermediate_ca.intermediate_ca_pem_certificate
  scep_allowed_ips               = var.scep_allowed_ips
  scep_iam_members               = var.scep_iam_members
  service_account_email          = module.stepca.service_account_email
  machine_type                   = var.machine_type
  zone                           = var.zone
  boot_disk_size                 = var.boot_disk_size
  boot_disk_type                 = var.boot_disk_type
  network_name                   = module.network.network_name
  subnet_name                    = module.network.subnet_name
  region                         = var.region
  connection_draining_timeout    = var.connection_draining_timeout
  backend_timeout_sec            = var.backend_timeout_sec
  autoscale_max_instances        = var.autoscale_max_instances
  autoscale_min_instances        = var.autoscale_min_instances
  autoscale_cooldown_period      = var.autoscale_cooldown_period
  network_self_link              = module.network.vpc_self_link
  subnet_self_link               = module.network.subnet_self_link
}

# Optional: DNS validation for ACME
resource "google_dns_managed_zone" "validation_zone" {
  count = var.acme_validation_enabled ? 1 : 0

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
  rrdatas = [module.scep_endpoint.scep_ip_address]
}
