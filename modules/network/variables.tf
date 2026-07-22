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

variable "region" {
  description = "Google Cloud region for Compute resources"
  type        = string
  default     = "us-central1"
}