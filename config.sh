#!/bin/bash
# Device Trust Certificate Configuration
# This file contains configuration variables for the device trust setup
#
# Populate these from the deployed infrastructure rather than editing the
# placeholders below directly:
#   SCEP_SERVER_URL: terraform output -raw scep_gateway_ip   (use as https://<ip>)
#   SCEP_CHALLENGE:  terraform output -raw scep_challenge_password
#   ROOT_CA_FILE_SRC: terraform output -raw root_ca_certificate > root-ca.crt
#   INTERMEDIATE_CA_FILE_SRC (optional, macOS/Windows): terraform output -raw
#     intermediate_ca_certificate > intermediate-ca.crt - lets the device
#     cert's PKCS#12/PFX bundle include the full chain instead of relying on
#     AIA fetching.
# SCEP_PROVISIONER matches the provisioner name in
# modules/stepca_container/templates/ca.json.tftpl ("device-trust-scep");
# only change it if that template changes too.

# SCEP Server Configuration
SCEP_SERVER_URL="${SCEP_SERVER_URL:-}"
SCEP_PROVISIONER="${SCEP_PROVISIONER:-device-trust-scep}"
SCEP_CHALLENGE="${SCEP_CHALLENGE:-}"
INTERMEDIATE_CA_FILE_SRC="${INTERMEDIATE_CA_FILE_SRC:-}"

# Certificate Subject Configuration
CERT_COUNTRY="${CERT_COUNTRY:-US}"
CERT_ORGANIZATION="${CERT_ORGANIZATION:-DeviceTrust}"
CERT_OU="${CERT_OU:-DeviceTrust}"

# Installation Paths
INSTALL_DIR="/usr/local/bin"
# Per-user, not /etc - scepclient (and the keychain trust/import steps) run
# as the invoking user, not root, so this needs to be writable by them.
CERT_DIR="${HOME}/.device-trust"
ROOT_CA_FILE="${CERT_DIR}/root-ca.crt"
INTERMEDIATE_CA_FILE="${CERT_DIR}/intermediate-ca.crt"
PRIVATE_KEY_FILE="${CERT_DIR}/client.key"
CERT_FILE="${CERT_DIR}/client.crt"
FULL_CHAIN_FILE="${CERT_DIR}/full-chain.pem"
