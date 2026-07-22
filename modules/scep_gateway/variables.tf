variable "scep_gateway_name" {
  description = "Base name for the SCEP gateway load balancer resources"
  type        = string
  default     = "scep-gateway"
}

variable "stepca_instance_group_id" {
  description = "ID of the (unmanaged) instance group containing the step-ca VM this gateway fronts"
  type        = string
}

variable "stepca_port" {
  description = "Port on which step-ca listens on its VM"
  type        = number
  default     = 9000
}

variable "ca_pool_name" {
  description = "Short name of the CA pool containing the intermediate CA, used to sign the gateway's TLS certificate"
  type        = string
}

variable "intermediate_ca_name" {
  description = "Short certificate_authority_id of the intermediate CA, used to sign the gateway's TLS certificate"
  type        = string
}

variable "location" {
  description = "Google Cloud location for Private CA operations (e.g., us-central1)"
  type        = string
  default     = "us-central1"
}

variable "region" {
  description = "Google Cloud region for Compute resources (e.g., us-central1)"
  type        = string
  default     = "us-central1"
}
