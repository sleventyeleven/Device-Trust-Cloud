# Connector for SCEP Module (AWS)
# A fully managed SCEP front end for AWS Private CA. No VM, no Docker, no
# step-ca config - AWS runs the SCEP protocol implementation, CA
# communication, and challenge-password enforcement itself. Defaults to
# Public connectivity (an AWS-managed public HTTPS endpoint), matching the
# GCP design's path-restricted-but-public SCEP gateway. Set var.vpc_endpoint_id
# to switch to Private connectivity via AWS PrivateLink instead.

resource "awscc_pcaconnectorscep_connector" "this" {
  certificate_authority_arn = var.intermediate_ca_arn
  vpc_endpoint_id           = var.vpc_endpoint_id
  tags                      = var.tags
}

resource "awscc_pcaconnectorscep_challenge" "this" {
  connector_arn = awscc_pcaconnectorscep_connector.this.connector_arn
  tags          = var.tags
}

# GetChallengePassword isn't part of the resource's own state - see the
# script for why this shells out instead of reading a normal attribute.
data "external" "challenge_password" {
  program = ["bash", "${path.module}/scripts/get-challenge-password.sh"]

  query = {
    challenge_arn = awscc_pcaconnectorscep_challenge.this.challenge_arn
    region        = var.region
  }
}
