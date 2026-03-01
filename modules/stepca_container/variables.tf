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

variable "vpc_connector_name" {
  description = "Name of the VPC connector for Cloud Run"
  type        = string
  default     = "device-trust-connector"
}

variable "project_id" {
  description = "Google Cloud project ID"
  type        = string
  default     = ""
}

variable "location" {
  description = "Google Cloud region/zone location"
  type        = string
  default     = "us-central1"
}

variable "health_check_enabled" {
  description = "Enable health checks for Cloud Run service"
  type        = bool
  default     = true
}

variable "all_traffic" {
  description = "Enable all traffic for Cloud Run service"
  type        = bool
  default     = true
}