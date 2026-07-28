output "root_ca_arn" {
  description = "ARN of the root CA"
  value       = module.root_ca.arn
}

output "root_ca_certificate" {
  description = "PEM-encoded root CA certificate"
  value       = module.root_ca.certificate_pem
  sensitive   = true
}

output "intermediate_ca_arn" {
  description = "ARN of the intermediate CA"
  value       = module.intermediate_ca.arn
}

output "intermediate_ca_certificate" {
  description = "PEM-encoded intermediate CA certificate"
  value       = module.intermediate_ca.certificate_pem
  sensitive   = true
}

output "connector_arn" {
  description = "ARN of the Connector for SCEP"
  value       = module.connector_scep.connector_arn
}

output "scep_endpoint_url" {
  description = "Full SCEP URL. This is already a complete path - unlike the GCP design, do not append /scep/<provisioner> to it (see the Enrollment section in the main Readme for the install scripts' full-URL override)"
  value       = module.connector_scep.scep_endpoint_url
}

output "scep_challenge_password" {
  description = "Shared secret SCEP clients must present to enroll (terraform output -raw scep_challenge_password)"
  value       = module.connector_scep.challenge_password
  sensitive   = true
}

output "mtls_gateway_url" {
  description = "URL of the nginx mTLS test gateway (empty if enable_mtls_test_gateway is false)"
  value       = var.enable_mtls_test_gateway ? module.mtls_test_gateway[0].url : ""
}
