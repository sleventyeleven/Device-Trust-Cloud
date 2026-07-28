output "connector_arn" {
  value = awscc_pcaconnectorscep_connector.this.connector_arn
}

output "scep_endpoint_url" {
  description = "Full SCEP URL - already a complete path, do not append /scep/<provisioner> to it"
  value       = awscc_pcaconnectorscep_connector.this.endpoint
}

output "challenge_arn" {
  value = awscc_pcaconnectorscep_challenge.this.challenge_arn
}

output "challenge_password" {
  description = "Plaintext SCEP challenge password, fetched via GetChallengePassword"
  value       = data.external.challenge_password.result.password
  sensitive   = true
}
