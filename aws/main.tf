# Device Trust PKI Infrastructure (AWS)
# AWS Private CA root + intermediate, AWS Private CA's Connector for SCEP
# as the fully managed SCEP front end (no step-ca VM, no Docker, no custom
# load balancer - see docs/aws-details.md for why this option was chosen
# over running step-ca against AWS Private CA), and the same nginx mTLS
# test gateway pattern used on the GCP side.

data "aws_availability_zones" "available" {
  state = "available"
}

module "network" {
  source = "./modules/network"

  name_prefix       = var.name_prefix
  availability_zone = data.aws_availability_zones.available.names[0]
}

module "root_ca" {
  source = "./modules/root_ca"

  common_name    = "${var.name_prefix}-root-ca"
  organization   = var.organization
  validity_years = var.root_ca_validity_years
  tags           = var.tags
}

module "intermediate_ca" {
  source = "./modules/intermediate_ca"

  root_ca_arn             = module.root_ca.arn
  root_ca_certificate_pem = module.root_ca.certificate_pem
  common_name             = "${var.name_prefix}-intermediate-ca"
  organization            = var.organization
  validity_years          = var.intermediate_ca_validity_years
  tags                    = var.tags

  # certificate_authority_arn = var.root_ca_arn only depends on the root CA
  # being *created*; it must also be *activated* (certificate installed)
  # before it can sign the intermediate's CSR. depends_on at the module
  # boundary here is what actually enforces that ordering.
  depends_on = [module.root_ca]
}

module "connector_scep" {
  source = "./modules/connector_scep"

  intermediate_ca_arn = module.intermediate_ca.arn
  region              = var.region
  vpc_endpoint_id     = var.scep_vpc_endpoint_id
  tags                = var.tags

  depends_on = [module.intermediate_ca]
}

module "mtls_test_gateway" {
  source = "./modules/mtls_test_gateway"
  count  = var.enable_mtls_test_gateway ? 1 : 0

  mtls_gateway_name               = "${var.name_prefix}-mtls-test-gateway"
  vpc_id                          = module.network.vpc_id
  public_subnet_id                = module.network.public_subnet_id
  region                          = var.region
  intermediate_ca_arn             = module.intermediate_ca.arn
  intermediate_ca_certificate_pem = module.intermediate_ca.certificate_pem
  root_ca_certificate_pem         = module.root_ca.certificate_pem
  tags                            = var.tags

  depends_on = [module.intermediate_ca]
}
