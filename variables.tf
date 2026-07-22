# Project and Location Variables
variable "project_id" {
  description = "Google Cloud project ID"
  type        = string
  default     = null
}

variable "location" {
  description = "Google Cloud region/zone location (e.g., us-central1)"
  type        = string
  default     = "us-central1"
}

variable "region" {
  description = "Google Cloud region for Compute resources (e.g., us-central1)"
  type        = string
  default     = "us-central1"
}

variable "gcp_apis_to_enable" {
  description = "GCP APIs to enable on the project before creating any resources"
  type        = list(string)
  default = [
    "compute.googleapis.com",
    "privateca.googleapis.com",
    "dns.googleapis.com",
    "iam.googleapis.com",
    "secretmanager.googleapis.com",
    "storage.googleapis.com",
  ]
}

# Network Configuration
variable "network_name" {
  description = "Name of the VPC network"
  type        = string
  default     = "device-trust-network"
}

variable "subnet_cidr_range" {
  description = "CIDR range for the VPC subnet"
  type        = string
  default     = "10.0.0.0/24"
}

variable "subnet_name" {
  description = "Name of the subnet"
  type        = string
  default     = "device-trust-subnet"
}

# CA Pool Configuration
variable "ca_pool_name" {
  description = "Name of the Certificate Authority pool"
  type        = string
  default     = "device-trust-ca-pool"
}

variable "root_ca_pool_name" {
  description = "Name of the root CA pool"
  type        = string
  default     = "root-ca-pool"
}

variable "ca_pool_tier" {
  description = "CA pool tier (STANDARD or ENTERPRISE)"
  type        = string
  default     = "ENTERPRISE"
}

variable "enable_root_publishing" {
  description = "Enable CA certificate/CRL publishing for the root CA pool"
  type        = bool
  default     = true
}

variable "enable_publishing" {
  description = "Enable CA certificate/CRL publishing for the CA pool"
  type        = bool
  default     = true
}

variable "stepca_iam_members" {
  description = "Additional IAM members (beyond the step-ca service account) granted issuer/templateUser roles on the CA pools"
  type        = list(string)
  default     = []
}

# Root CA Configuration
variable "root_ca_name" {
  description = "Name of the root CA"
  type        = string
  default     = "root-ca"
}

variable "root_ca_lifetime" {
  description = "Root CA certificate lifetime in seconds (default: 10 years)"
  type        = string
  default     = "31536000s"  # 10 years
}

variable "root_ca_key_algorithm" {
  description = "Algorithm for root CA private key"
  type        = string
  default     = "RSA_PKCS1_4096_SHA256"
}

variable "root_ca_gcs_bucket" {
  description = "Cloud Storage bucket for publishing the root CA certificate/CRLs"
  type        = string
  default     = ""
}

# Intermediate CA Configuration
variable "intermediate_ca_name" {
  description = "Name of the intermediate CA"
  type        = string
  default     = "intermediate-ca"
}

variable "intermediate_ca_lifetime" {
  description = "Intermediate CA certificate lifetime in seconds (default: 5 years)"
  type        = string
  default     = "15768000s"  # 5 years
}

variable "intermediate_ca_key_algorithm" {
  description = "Algorithm for intermediate CA private key"
  type        = string
  default     = "RSA_PKCS1_2048_SHA256"
}

# Certificate Template Configuration
variable "certificate_template_name" {
  description = "Name of the certificate template for SCEP"
  type        = string
  default     = "device-trust-scep-template"
}

variable "certificate_template_description" {
  description = "Description of the certificate template"
  type        = string
  default     = "Certificate template for device trust with SCEP"
}

# Step-ca Configuration
variable "stepca_instance_name" {
  description = "Base name for the step-ca VM and related resources"
  type        = string
  default     = "step-ca"
}

variable "stepca_container_image" {
  description = "Docker image for step-ca"
  type        = string
  default     = "smallstep/step-ca:latest"
}

variable "stepca_port" {
  description = "Port on which step-ca listens"
  type        = number
  default     = 9000
}

variable "stepca_domain" {
  description = "Domain for step-ca (used as the TLS SAN in ca.json), if applicable"
  type        = string
  default     = ""
}

variable "machine_type" {
  description = "Machine type for the step-ca VM"
  type        = string
  default     = "e2-small"
}

variable "zone" {
  description = "Zone for the step-ca VM"
  type        = string
  default     = "us-central1-a"
}

# SCEP Gateway Configuration (path-restricted LB in front of the step-ca VM)
variable "scep_gateway_name" {
  description = "Base name for the SCEP gateway load balancer resources"
  type        = string
  default     = "scep-gateway"
}

# mTLS Test Gateway Configuration (public nginx ClientAuth test target)
variable "enable_mtls_test_gateway" {
  description = "Whether to deploy the nginx mTLS test gateway (a small public VM used to verify enrolled device certs work for TLS ClientAuth). Disable to avoid the extra VM cost once testing is done."
  type        = bool
  default     = true
}

variable "mtls_gateway_name" {
  description = "Base name for the mTLS test gateway VM and related resources"
  type        = string
  default     = "mtls-test-gateway"
}

variable "mtls_gateway_machine_type" {
  description = "Machine type for the mTLS test gateway VM"
  type        = string
  default     = "e2-small"
}

# Service Account Configuration
variable "service_account_name" {
  description = "Base name for service accounts"
  type        = string
  default     = "device-trust"
}

variable "service_account_display_name" {
  description = "Display name for service accounts"
  type        = string
  default     = "Device Trust Service Accounts"
}

variable "impersonate_service_account" {
  description = "Service account to impersonate"
  type        = string
  default     = ""
}

# ACME DNS Validation Configuration
variable "acme_validation_enabled" {
  description = "Enable a managed DNS zone and CNAME record for ACME challenge validation"
  type        = bool
  default     = false
}

variable "acme_dns_zone_name" {
  description = "DNS name for the ACME validation managed zone (e.g., \"example.com.\")"
  type        = string
  default     = ""
}

variable "acme_challenge_token" {
  description = "ACME challenge token used as the record name prefix"
  type        = string
  default     = ""
}

variable "acme_validation_ttl" {
  description = "TTL in seconds for the ACME validation DNS record"
  type        = number
  default     = 300
}

# Output Variables
output "root_ca_id" {
  description = "ID of the root CA"
  value       = module.root_ca.root_ca_id
}

output "root_ca_certificate" {
  description = "PEM-encoded root CA certificate"
  value       = module.root_ca.root_ca_pem_certificate
  sensitive   = true
}

output "intermediate_ca_id" {
  description = "ID of the intermediate CA"
  value       = module.intermediate_ca.intermediate_ca_id
}

output "intermediate_ca_certificate" {
  description = "PEM-encoded intermediate CA certificate"
  value       = module.intermediate_ca.intermediate_ca_pem_certificate
  sensitive   = true
}

output "ca_pool_id" {
  description = "ID of the CA pool"
  value       = module.ca_pool.ca_pool_id
}

output "certificate_template_id" {
  description = "ID of the certificate template"
  value       = module.certificate_template.certificate_template_id
}

output "scep_endpoint_url" {
  description = "URL for the SCEP enrollment endpoint (only /scep/* is publicly reachable through the gateway)"
  value       = module.scep_gateway.scep_url
}

output "scep_gateway_ip" {
  description = "Static public IP of the SCEP gateway load balancer"
  value       = module.scep_gateway.scep_gateway_ip
}

output "service_account_email" {
  description = "Email address of the step-ca service account"
  value       = module.stepca.service_account_email
  sensitive   = true
}

output "scep_challenge_password" {
  description = "Shared secret SCEP clients must present to enroll (terraform output -raw scep_challenge_password)"
  value       = module.stepca.scep_challenge_password
  sensitive   = true
}

output "network_self_link" {
  description = "Self-link of the network"
  value       = module.network.vpc_self_link
}

output "subnet_self_link" {
  description = "Self-link of the subnet"
  value       = module.network.subnet_self_link
}

output "mtls_gateway_url" {
  description = "URL of the nginx mTLS test gateway, used to verify enrolled device certs work for TLS ClientAuth (empty if enable_mtls_test_gateway is false)"
  value       = var.enable_mtls_test_gateway ? module.mtls_test_gateway[0].mtls_gateway_url : ""
}
