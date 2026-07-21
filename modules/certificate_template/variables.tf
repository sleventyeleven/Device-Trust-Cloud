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

variable "maximum_lifetime" {
  description = "Maximum lifetime allowed for certificates issued using this template (e.g. \"31536000s\"). Null means no override."
  type        = string
  default     = null
}
