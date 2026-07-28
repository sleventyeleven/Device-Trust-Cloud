#!/usr/bin/env bash
# Terraform external data source helper.
#
# AWS Connector for SCEP generates its own challenge password when a
# Challenge resource is created, and only exposes it via the
# GetChallengePassword API - it is not a Terraform resource attribute (the
# awscc_pcaconnectorscep_challenge resource only exposes challenge_arn/id).
# This script bridges that gap so `terraform output` can still surface the
# plaintext password the same way `random_password.scep_challenge` does on
# the GCP side.
set -euo pipefail

QUERY=$(cat)
CHALLENGE_ARN=$(echo "$QUERY" | jq -r '.challenge_arn')
REGION=$(echo "$QUERY" | jq -r '.region')

PASSWORD=$(aws pca-connector-scep get-challenge-password \
  --challenge-arn "$CHALLENGE_ARN" \
  --region "$REGION" \
  --query Password \
  --output text)

jq -n --arg password "$PASSWORD" '{password: $password}'
