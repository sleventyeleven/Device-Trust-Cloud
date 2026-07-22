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

variable "stepca_instance_name" {
  description = "Base name for the step-ca VM and related resources"
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

variable "stepca_domain" {
  description = "Domain for step-ca (used as the TLS SAN in ca.json), if applicable"
  type        = string
  default     = ""
}

variable "ca_pool_name" {
  description = "Short name of the CA pool containing the intermediate CA, used to sign the SCEP decrypter certificate"
  type        = string
}

variable "intermediate_ca_name" {
  description = "Short certificate_authority_id of the intermediate CA, used to sign the SCEP decrypter certificate"
  type        = string
}

variable "intermediate_ca_resource_id" {
  description = "Full CAS resource path of the intermediate CA (projects/.../caPools/.../certificateAuthorities/...) that step-ca's cloudCAS RA delegates signing to"
  type        = string
}

variable "ca_pool_iam_binding_ids" {
  description = "IDs of the CA pool IAM bindings this module's service account needs; passed in (rather than a module-level depends_on) to avoid a dependency cycle, since the ca_pool module also depends on this module's service account email. Kept for parity even though nothing in this module currently waits on it directly."
  type        = list(string)
  default     = []
}

variable "machine_type" {
  description = "Machine type for the step-ca VM"
  type        = string
  default     = "e2-small"
}

variable "zone" {
  description = "Zone for the step-ca VM"
  type        = string
  default     = "us-central1-a"
}

variable "network_name" {
  description = "Name of the VPC network the step-ca VM attaches to"
  type        = string
}

variable "subnet_name" {
  description = "Name of the subnet the step-ca VM attaches to"
  type        = string
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
