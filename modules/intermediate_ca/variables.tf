variable "intermediate_ca_name" {
  description = "Name of the intermediate CA"
  type        = string
  default     = "intermediate-ca"
}

variable "ca_pool_name" {
  description = "Name of the CA pool"
  type        = string
  default     = "device-trust-ca-pool"
}

variable "parent_ca_resource_name" {
  description = "Resource name of the root CA that issues this intermediate CA (root_ca module's root_ca_name output)"
  type        = string
}

variable "root_ca_pem_certificate" {
  description = "PEM-encoded root CA certificate, used to build the full certificate chain output"
  type        = string
  sensitive   = true
  default     = ""
}

variable "key_algorithm" {
  description = "Algorithm for intermediate CA private key"
  type        = string
  default     = "RSA_PKCS1_2048_SHA256"
}

variable "lifetime" {
  description = "Intermediate CA certificate lifetime in seconds (default: 5 years)"
  type        = string
  default     = "15768000s"  # 5 years
}

variable "location" {
  description = "Google Cloud region/zone location"
  type        = string
  default     = "us-central1"
}