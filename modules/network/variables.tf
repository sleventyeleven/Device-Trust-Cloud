variable "network_name" {
  description = "Name of the VPC network"
  type        = string
  default     = "device-trust-network"
}

variable "subnet_cidr_range" {
  description = "CIDR range for the VPC subnet"
  type        = string
  default     = "10.0.0.0/24"
}

variable "subnet_name" {
  description = "Name of the subnet"
  type        = string
  default     = "device-trust-subnet"
}

variable "vpc_connector_name" {
  description = "Name of the VPC connector for Cloud Run"
  type        = string
  default     = "device-trust-connector"
}

variable "vpc_connector_min_instances" {
  description = "Minimum number of instances for VPC connector"
  type        = number
  default     = 0
}

variable "vpc_connector_max_instances" {
  description = "Maximum number of instances for VPC connector"
  type        = number
  default     = 10
}

variable "vpc_connector_machine_type" {
  description = "Machine type for VPC connector"
  type        = string
  default     = "E2"
}

variable "region" {
  description = "Google Cloud region for Compute resources"
  type        = string
  default     = "us-central1"
}