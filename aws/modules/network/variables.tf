variable "name_prefix" {
  description = "Prefix applied to resource Name tags"
  type        = string
  default     = "device-trust"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.42.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public subnet"
  type        = string
  default     = "10.42.1.0/24"
}

variable "availability_zone" {
  description = "Availability zone for the public subnet"
  type        = string
}
