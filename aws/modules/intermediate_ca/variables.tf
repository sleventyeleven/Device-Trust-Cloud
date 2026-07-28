variable "root_ca_arn" {
  description = "ARN of the activated root CA that will sign this intermediate"
  type        = string
}

variable "root_ca_certificate_pem" {
  description = "PEM-encoded root CA certificate, appended to the intermediate's own certificate to form its certificate_chain"
  type        = string
}

variable "common_name" {
  description = "Common name for the intermediate CA"
  type        = string
  default     = "device-trust-intermediate-ca"
}

variable "organization" {
  description = "Organization name on the intermediate CA's subject"
  type        = string
  default     = "Device Trust Infrastructure"
}

variable "key_algorithm" {
  description = "Key algorithm for the intermediate CA"
  type        = string
  default     = "RSA_2048"
}

variable "signing_algorithm" {
  description = "Signing algorithm for the intermediate CA and the certificates it issues"
  type        = string
  default     = "SHA256WITHRSA"
}

variable "validity_years" {
  description = "Intermediate CA certificate validity, in years"
  type        = number
  default     = 5
}

variable "permanent_deletion_time_in_days" {
  description = "Mandatory pending-deletion window before AWS permanently purges the CA (7-30). Does not block terraform destroy from succeeding."
  type        = number
  default     = 7
}

variable "tags" {
  description = "Tags applied to the intermediate CA"
  type        = map(string)
  default     = {}
}
