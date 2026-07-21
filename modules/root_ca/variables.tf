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