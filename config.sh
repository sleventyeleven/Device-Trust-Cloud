#!/bin/bash
# Device Trust Certificate Configuration
# This file contains configuration variables for the device trust setup

# SCEP Server Configuration
SCEP_SERVER_URL="${SCEP_SERVER_URL:-https://step-ca.example.com}"
SCEP_PROVISIONER="${SCEP_PROVISIONER:-poc_devicetrust}"
SCEP_CHALLENGE="${SCEP_CHALLENGE:-your-secret-challenge}"

# Certificate Subject Configuration
CERT_COUNTRY="${CERT_COUNTRY:-US}"
CERT_ORGANIZATION="${CERT_ORGANIZATION:-DeviceTrust}"
CERT_OU="${CERT_OU:-Device Trust}"

# Installation Paths
INSTALL_DIR="/usr/local/bin"
CERT_DIR="/etc/device-trust"
ROOT_CA_FILE="${CERT_DIR}/root-ca.crt"
PRIVATE_KEY_FILE="${CERT_DIR}/client.key"
CERT_FILE="${CERT_DIR}/client.crt"
FULL_CHAIN_FILE="${CERT_DIR}/full-chain.pem"