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

variable "vpc_connector_name" {
  description = "Name of the VPC connector for Cloud Run"
  type        = string
  default     = "device-trust-connector"
}

variable "vpc_connector_min_instances" {
  description = "Minimum number of instances for VPC connector"
  type        = number
  default     = 0
}

variable "vpc_connector_max_instances" {
  description = "Maximum number of instances for VPC connector"
  type        = number
  default     = 10
}

variable "vpc_connector_machine_type" {
  description = "Machine type for VPC connector"
  type        = string
  default     = "E2"
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
variable "stepca_service_name" {
  description = "Name of the Cloud Run service for step-ca"
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

variable "stepca_fingerprint" {
  description = "CA certificate fingerprint (SHA-256)"
  type        = string
  default     = ""
}

variable "stepca_domain" {
  description = "Domain for step-ca (used for ACME, if applicable)"
  type        = string
  default     = ""
}

variable "stepca_ca_config" {
  description = "Additional CA configuration (as YAML string)"
  type        = string
  default     = ""
}

variable "stepca_grace_period_days" {
  description = "Grace period in days for certificate revocation"
  type        = number
  default     = 30
}

variable "min_instances" {
  description = "Minimum number of instances for Cloud Run"
  type        = number
  default     = 0
}

variable "max_instances" {
  description = "Maximum number of instances for Cloud Run"
  type        = number
  default     = 10
}

variable "managed_domain_enabled" {
  description = "Enable Cloud Run domain mapping for step-ca"
  type        = bool
  default     = false
}

variable "vpc_connector_enabled" {
  description = "Enable VPC connector for Cloud Run"
  type        = bool
  default     = true
}

# SCEP Endpoint Configuration
variable "scep_endpoint_name" {
  description = "Name of the SCEP endpoint load balancer"
  type        = string
  default     = "scep-endpoint"
}

variable "scep_allowed_ips" {
  description = "List of allowed IP ranges for SCEP access"
  type        = list(string)
  default     = []
}

variable "scep_iam_members" {
  description = "List of IAM member roles for the SCEP endpoint instance"
  type        = list(string)
  default     = []
}

variable "scep_port" {
  description = "Port for SCEP endpoint"
  type        = number
  default     = 80
}

variable "machine_type" {
  description = "Machine type for the SCEP instance"
  type        = string
  default     = "e2-medium"
}

variable "zone" {
  description = "Zone for the SCEP instance"
  type        = string
  default     = "us-central1-a"
}

variable "boot_disk_size" {
  description = "Boot disk size in GB for the SCEP instance"
  type        = number
  default     = 20
}

variable "boot_disk_type" {
  description = "Boot disk type for the SCEP instance"
  type        = string
  default     = "pd-balanced"
}

variable "connection_draining_timeout" {
  description = "Connection draining timeout in seconds for the SCEP backend service"
  type        = number
  default     = 300
}

variable "backend_timeout_sec" {
  description = "Backend service timeout in seconds for the SCEP backend service"
  type        = number
  default     = 300
}

variable "autoscale_max_instances" {
  description = "Maximum number of autoscale instances for the SCEP instance group"
  type        = number
  default     = 10
}

variable "autoscale_min_instances" {
  description = "Minimum number of autoscale instances for the SCEP instance group"
  type        = number
  default     = 1
}

variable "autoscale_cooldown_period" {
  description = "Autoscale cooldown period in seconds for the SCEP instance group"
  type        = number
  default     = 60
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

output "stepca_url" {
  description = "URL for step-ca service"
  value       = module.stepca.stepca_url
}

output "scep_endpoint_url" {
  description = "URL for SCEP endpoint"
  value       = module.scep_endpoint.scep_url
}

output "vpc_connector_self_link" {
  description = "Self-link of the VPC connector"
  value       = module.network.vpc_connector_self_link
}

output "service_account_email" {
  description = "Email address of the step-ca service account"
  value       = module.stepca.service_account_email
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
