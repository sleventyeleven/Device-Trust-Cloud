variable "intermediate_ca_arn" {
  description = "ARN of the activated intermediate CA this connector issues certificates from"
  type        = string
}

variable "region" {
  description = "AWS region, passed through to the GetChallengePassword CLI call"
  type        = string
}

variable "vpc_endpoint_id" {
  description = "VPC endpoint ID for Private connectivity. Leave null for Public connectivity (an AWS-managed public endpoint)."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to the connector and challenge"
  type        = map(string)
  default     = {}
}
