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

variable "root_ca_enable_publishing" {
  description = "Enable CA certificate publishing"
  type        = bool
  default     = true
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

variable "certificate_template_key_size" {
  description = "Key size for certificates issued by this template"
  type        = number
  default     = 2048
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

# SCEP Endpoint Configuration
variable "scep_endpoint_name" {
  description = "Name of the SCEP endpoint load balancer"
  type        = string
  default     = "scep-endpoint"
}

variable "scep_cert_template" {
  description = "Name of the certificate template for SCEP clients"
  type        = string
  default     = "device-trust-scep-template"
}

variable "scep_client_auth_enabled" {
  description = "Enable client certificate authentication for SCEP endpoint"
  type        = bool
  default     = true
}

variable "scep_allow_unauthenticated" {
  description = "Allow unauthenticated access (useful for testing)"
  type        = bool
  default     = false
}

variable "scep_allowed_ips" {
  description = "List of allowed IP ranges for SCEP access"
  type        = list(string)
  default     = []
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

# Workload Identity Configuration
variable "workload_identity_provider" {
  description = "Workload identity provider ID for GKE authentication"
  type        = string
  default     = ""
}

variable "workload_identity_pool" {
  description = "Workload identity pool ID"
  type        = string
  default     = ""
}

variable "workload_identity_pool_provider" {
  description = "Workload identity pool provider ID"
  type        = string
  default     = ""
}

variable "impersonate_service_account" {
  description = "Service account to impersonate"
  type        = string
  default     = ""
}

# Output Variables
output "root_ca_issuer" {
  description = "Root CA issuer URL"
  value       = google_privateca_certificate_authority.root_ca.issuer_certificate_url
}

output "root_ca_certificate" {
  description = "Root CA certificate content"
  value       = google_privateca_certificate_authority.root_ca.certificates[0]
  sensitive   = true
}

output "intermediate_ca_issuer" {
  description = "Intermediate CA issuer URL"
  value       = google_privateca_certificate_authority.intermediate_ca.issuer_certificate_url
}

output "intermediate_ca_certificate" {
  description = "Intermediate CA certificate content"
  value       = google_privateca_certificate_authority.intermediate_ca.certificates[0]
  sensitive   = true
}

output "ca_pool_id" {
  description = "ID of the CA pool"
  value       = google_privateca_ca_pool.ca_pool.id
}

output "certificate_template_id" {
  description = "ID of the certificate template"
  value       = google_privateca_certificate_template.scep_template.id
}

output "stepca_url" {
  description = "URL for step-ca service"
  value       = "https://${google_cloud_run_service.stepca.status.url[0]}"
}

output "scep_endpoint_url" {
  description = "URL for SCEP endpoint"
  value       = "https://${google_compute_global_forwarding_rule.scep_forwarding_rule.ip_address}"
}

output "vpc_connector_self_link" {
  description = "Self-link of the VPC connector"
  value       = google_vpc_access_connector.connector.self_link
}

output "service_account_email" {
  description = "Email address of the step-ca service account"
  value       = google_service_account.sa_stepca.email
  sensitive   = true
}

output "network_self_link" {
  description = "Self-link of the network"
  value       = google_compute_network.vpc.self_link
}

output "subnet_self_link" {
  description = "Self-link of the subnet"
  value       = google_compute_subnet.subnet.self_link
}

output "ca_pool_certificate_authority_id" {
  description = "ID of the CA pool's certificate authority"
  value       = google_privateca_certificate_authority.root_ca.id
}