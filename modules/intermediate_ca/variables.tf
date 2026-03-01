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

variable "root_ca_name" {
  description = "Name of the root CA to use as parent"
  type        = string
  default     = "root-ca"
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

variable "intermediate_ca_iam_members" {
  description = "List of IAM member roles for intermediate CA"
  type        = list(string)
  default     = []
}

variable "location" {
  description = "Google Cloud region/zone location"
  type        = string
  default     = "us-central1"
}