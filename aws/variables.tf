variable "region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Prefix applied to resource names/tags across all modules"
  type        = string
  default     = "device-trust"
}

variable "organization" {
  description = "Organization name on the CA subjects"
  type        = string
  default     = "Device Trust Infrastructure"
}

variable "root_ca_validity_years" {
  type    = number
  default = 10
}

variable "intermediate_ca_validity_years" {
  type    = number
  default = 5
}

variable "scep_vpc_endpoint_id" {
  description = "VPC endpoint ID for Private connectivity on the SCEP connector. Leave null for Public connectivity (an AWS-managed public endpoint), which is the default and mirrors the GCP design's public path-restricted gateway."
  type        = string
  default     = null
}

variable "enable_mtls_test_gateway" {
  description = "Deploy the nginx mTLS test gateway used to verify enrolled certs actually work for ClientAuth. Set to false to skip it (saves one small EC2 instance) once enrollment is verified."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied across all resources that support them"
  type        = map(string)
  default     = {}
}
