variable "common_name" {
  description = "Common name for the root CA"
  type        = string
  default     = "device-trust-root-ca"
}

variable "organization" {
  description = "Organization name on the root CA's subject"
  type        = string
  default     = "Device Trust Infrastructure"
}

variable "key_algorithm" {
  description = "Key algorithm for the root CA"
  type        = string
  default     = "RSA_2048"
}

variable "signing_algorithm" {
  description = "Signing algorithm for the root CA and the certificates it issues"
  type        = string
  default     = "SHA256WITHRSA"
}

variable "validity_years" {
  description = "Root CA certificate validity, in years"
  type        = number
  default     = 10
}

variable "permanent_deletion_time_in_days" {
  description = "Mandatory pending-deletion window before AWS permanently purges the CA (7-30). Unlike GCP, this does not block terraform destroy from succeeding - it only affects how long the CA sits in a DELETED/recoverable state afterward."
  type        = number
  default     = 7
}

variable "tags" {
  description = "Tags applied to the root CA"
  type        = map(string)
  default     = {}
}
