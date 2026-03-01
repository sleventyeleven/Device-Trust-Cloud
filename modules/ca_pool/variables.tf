variable "root_ca_pool_name" {
  description = "Name of the root CA pool"
  type        = string
  default     = "root-ca-pool"
}

variable "ca_pool_name" {
  description = "Name of the CA pool"
  type        = string
  default     = "device-trust-ca-pool"
}

variable "ca_pool_tier" {
  description = "CA pool tier (STANDARD or ENTERPRISE)"
  type        = string
  default     = "ENTERPRISE"
}

variable "enable_root_publishing" {
  description = "Enable CA certificate publishing for root pool"
  type        = bool
  default     = true
}

variable "enable_publishing" {
  description = "Enable CA certificate publishing"
  type        = bool
  default     = true
}

variable "location" {
  description = "Google Cloud region/zone location"
  type        = string
  default     = "us-central1"
}