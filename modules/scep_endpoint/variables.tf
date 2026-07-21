variable "scep_endpoint_name" {
  description = "Name of the SCEP endpoint load balancer"
  type        = string
  default     = "scep-endpoint"
}

variable "scep_port" {
  description = "Port for SCEP endpoint"
  type        = number
  default     = 80
}

variable "scep_ca_certificate" {
  description = "CA certificate for SCEP client (PEM-encoded)"
  type        = string
  default     = ""
}

variable "scep_allowed_ips" {
  description = "List of allowed IP ranges for SCEP access"
  type        = list(string)
  default     = []
}

variable "scep_iam_members" {
  description = "List of IAM member roles for SCEP endpoint"
  type        = list(string)
  default     = []
}

variable "service_account_email" {
  description = "Email of the service account the SCEP instance runs as"
  type        = string
  default     = ""
}

variable "machine_type" {
  description = "Machine type for SCEP instance"
  type        = string
  default     = "e2-medium"
}

variable "zone" {
  description = "Zone for SCEP instance"
  type        = string
  default     = "us-central1-a"
}

variable "boot_disk_size" {
  description = "Boot disk size in GB"
  type        = number
  default     = 20
}

variable "boot_disk_type" {
  description = "Boot disk type"
  type        = string
  default     = "pd-balanced"
}

variable "network_name" {
  description = "Name of the network"
  type        = string
  default     = "device-trust-network"
}

variable "subnet_name" {
  description = "Name of the subnet"
  type        = string
  default     = "device-trust-subnet"
}

variable "region" {
  description = "Google Cloud region"
  type        = string
  default     = "us-central1"
}

variable "connection_draining_timeout" {
  description = "Connection draining timeout in seconds"
  type        = number
  default     = 300
}

variable "backend_timeout_sec" {
  description = "Backend service timeout in seconds"
  type        = number
  default     = 300
}

variable "autoscale_max_instances" {
  description = "Maximum number of autoscale instances"
  type        = number
  default     = 10
}

variable "autoscale_min_instances" {
  description = "Minimum number of autoscale instances"
  type        = number
  default     = 1
}

variable "autoscale_cooldown_period" {
  description = "Autoscale cooldown period in seconds"
  type        = number
  default     = 60
}

variable "network_self_link" {
  description = "Self-link of the network"
  type        = string
  default     = ""
}

variable "subnet_self_link" {
  description = "Self-link of the subnet"
  type        = string
  default     = ""
}