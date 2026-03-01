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

variable "location" {
  description = "Google Cloud region/zone location"
  type        = string
  default     = "us-central1"
}

variable "key_algorithm" {
  description = "Key algorithm for certificates issued by this template"
  type        = string
  default     = "RSA_PKCS1_2048_SHA256"
}

variable "key_size" {
  description = "Key size for certificates issued by this template"
  type        = number
  default     = 2048
}

variable "default_country" {
  description = "Default country name for certificates"
  type        = string
  default     = "US"
}

variable "default_organization" {
  description = "Default organization name for certificates"
  type        = string
  default     = "Device Trust Infrastructure"
}

variable "default_common_name" {
  description = "Default common name for certificates"
  type        = string
  default     = "Device Trust"
}

variable "common_name" {
  description = "Common name for the template"
  type        = string
  default     = "Device Trust"
}

variable "organization" {
  description = "Organization for the template"
  type        = string
  default     = "Device Trust"
}

variable "country" {
  description = "Country for the template"
  type        = string
  default     = "US"
}

variable "organizational_unit" {
  description = "Organizational unit for the template"
  type        = string
  default     = ""
}

variable "locality" {
  description = "Locality for the template"
  type        = string
  default     = ""
}

variable "province" {
  description = "Province/State for the template"
  type        = string
  default     = ""
}

variable "street_address" {
  description = "Street address for the template"
  type        = string
  default     = ""
}

variable "postal_code" {
  description = "Postal code for the template"
  type        = string
  default     = ""
}

variable "dns_names" {
  description = "DNS names for the template"
  type        = list(string)
  default     = []
}

variable "email_addresses" {
  description = "Email addresses for the template"
  type        = list(string)
  default     = []
}

variable "ip_addresses" {
  description = "IP addresses for the template"
  type        = list(string)
  default     = []
}

variable "uris" {
  description = "URIs for the template"
  type        = list(string)
  default     = []
}

variable "valid_idp_ids" {
  description = "Valid IDP IDs for the template"
  type        = list(string)
  default     = []
}

variable "permitted_dns_names" {
  description = "Permitted DNS names for the template"
  type        = list(string)
  default     = []
}

variable "excluded_dns_names" {
  description = "Excluded DNS names for the template"
  type        = list(string)
  default     = []
}

variable "unknown_critical_key_usage_extensions" {
  description = "Unknown critical key usage extensions"
  type        = list(string)
  default     = []
}

variable "authority_info_access" {
  description = "Authority Information Access value"
  type        = string
  default     = ""
}