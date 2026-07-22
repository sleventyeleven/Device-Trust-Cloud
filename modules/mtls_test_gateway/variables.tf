variable "project_id" {
  description = "GCP project ID - set explicitly on each resource in this module since provider-level default project inheritance was observed to fail for this module in this environment"
  type        = string
}

variable "mtls_gateway_name" {
  description = "Base name for the mTLS test gateway VM and related resources"
  type        = string
  default     = "mtls-test-gateway"
}

variable "ca_pool_name" {
  description = "Short name of the CA pool containing the intermediate CA, used to sign the gateway's server TLS certificate"
  type        = string
}

variable "intermediate_ca_name" {
  description = "Short certificate_authority_id of the intermediate CA, used to sign the gateway's server TLS certificate"
  type        = string
}

variable "root_ca_pem_certificate" {
  description = "PEM-encoded root CA certificate, bundled into the client CA trust file nginx validates device certs against"
  type        = string
  sensitive   = true
}

variable "intermediate_ca_pem_certificate" {
  description = "PEM-encoded intermediate CA certificate, bundled into the client CA trust file nginx validates device certs against"
  type        = string
  sensitive   = true
}

variable "machine_type" {
  description = "Machine type for the mTLS test gateway VM"
  type        = string
  default     = "e2-small"
}

variable "zone" {
  description = "Zone for the mTLS test gateway VM"
  type        = string
  default     = "us-central1-a"
}

variable "network_name" {
  description = "Name of the VPC network the gateway VM attaches to"
  type        = string
}

variable "subnet_name" {
  description = "Name of the subnet the gateway VM attaches to"
  type        = string
}

variable "location" {
  description = "Google Cloud location for Private CA operations (e.g., us-central1)"
  type        = string
  default     = "us-central1"
}
