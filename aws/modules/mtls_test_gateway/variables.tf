variable "mtls_gateway_name" {
  description = "Name used for the instance, security group, IAM role, and secret"
  type        = string
  default     = "mtls-test-gateway"
}

variable "vpc_id" {
  type = string
}

variable "public_subnet_id" {
  type = string
}

variable "region" {
  description = "AWS region, passed to the instance for the Secrets Manager CLI call in user_data"
  type        = string
}

variable "intermediate_ca_arn" {
  type = string
}

variable "intermediate_ca_certificate_pem" {
  type = string
}

variable "root_ca_certificate_pem" {
  type = string
}

variable "signing_algorithm" {
  type    = string
  default = "SHA256WITHRSA"
}

variable "cert_validity_days" {
  description = "Server certificate validity, in days - short lived by design"
  type        = number
  default     = 90
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "tags" {
  type    = map(string)
  default = {}
}
