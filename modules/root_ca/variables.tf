variable "root_ca_name" {
  description = "Name of the root CA"
  type        = string
  default     = "root-ca"
}

variable "root_ca_pool_name" {
  description = "Name of the root CA pool"
  type        = string
  default     = "root-ca-pool"
}

variable "key_algorithm" {
  description = "Algorithm for root CA private key"
  type        = string
  default     = "RSA_PKCS1_4096_SHA256"
}

variable "lifetime" {
  description = "Root CA certificate lifetime in seconds (default: 10 years)"
  type        = string
  default     = "31536000s"  # 10 years
}

variable "root_ca_gcs_bucket" {
  description = "Cloud Storage bucket for publishing CA certificates"
  type        = string
  default     = ""
}

variable "location" {
  description = "Google Cloud region/zone location"
  type        = string
  default     = "us-central1"
}
variable "deletion_protection" {
  description = "Refuse to delete this CA. Leave on for anything real; turn off (with skip_grace_period and ignore_active_certificates_on_deletion) only to tear down a test environment"
  type        = bool
  default     = true
}

variable "skip_grace_period" {
  description = "Delete the CA immediately instead of keeping it in DELETED state for 30 days. Its ID can never be reused either way"
  type        = bool
  default     = false
}

variable "ignore_active_certificates_on_deletion" {
  description = "Allow deleting the CA even though it has issued certificates that have not expired or been revoked"
  type        = bool
  default     = false
}
