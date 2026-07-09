#!/bin/bash
# Device Trust Certificate Installation Script for macOS
# This script automates the installation of scepclient and requests a device trust certificate

set -e  # Exit on error

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "========================================"
echo "Device Trust Certificate Installation"
echo "========================================"
echo ""

# Configuration
SCEP_SERVER_URL="${SCEP_SERVER_URL:-https://step-ca.example.com}"
SCEP_PROVISIONER="${SCEP_PROVISIONER:-poc_devicetrust}"
SCEP_CHALLENGE="${SCEP_CHALLENGE:-your-secret-challenge}"
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

# Detect hostname for DNS name
HOSTNAME=$(hostname -s)

# Create installation directory
mkdir -p "$CERT_DIR"

echo "Configuration:"
echo "- SCEP Server: $SCEP_SERVER_URL"
echo "- Provisioner: $SCEP_PROVISIONER"
echo "- Hostname: $HOSTNAME"
echo "- Cert Directory: $CERT_DIR"
echo ""

# Download scepclient for macOS (amd64)
echo "Downloading scepclient for macOS..."
SCEPCLIENT_URL="https://github.com/micromdm/scep/releases/latest/download/scepclient-darwin-amd64"

if ! command -v curl &> /dev/null; then
    echo -e "${RED}Error: curl is not installed${NC}"
    exit 1
fi

if ! command -v wget &> /dev/null; then
    echo -e "${RED}Error: wget is not installed${NC}"
    exit 1
fi

# Try curl first, then wget
if command -v curl &> /dev/null; then
    curl -L -o "$INSTALL_DIR/scepclient" "$SCEPCLIENT_URL"
else
    wget -O "$INSTALL_DIR/scepclient" "$SCEPCLIENT_URL"
fi

# Make executable
chmod +x "$INSTALL_DIR/scepclient"

echo -e "${GREEN}✓ scepclient downloaded successfully${NC}"
echo ""

# Install root CA certificate
echo "Installing root CA certificate..."
set +e  # Don't exit on error for certificate installation

if [ -n "$ROOT_CA_URL" ]; then
    echo "Downloading root CA from: $ROOT_CA_URL"
    curl -L -o "$ROOT_CA_FILE" "$ROOT_CA_URL"
else
    echo -e "${YELLOW}Note: ROOT_CA_URL not set${NC}"
    echo "The root CA certificate must be manually installed."
fi

# Install root CA to system keychain
if [ -f "$ROOT_CA_FILE" ]; then
    sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$ROOT_CA_FILE"
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Root CA installed successfully${NC}"
    else
        echo -e "${RED}✗ Failed to install root CA to system keychain${NC}"
    fi
else
    echo -e "${YELLOW}⚠ Root CA certificate not found, but continuing...${NC}"
fi
set -e

echo ""

# Request device trust certificate
echo "========================================"
echo "Requesting Device Trust Certificate"
echo "========================================"
echo ""

# Build scepclient command
SCEPTOOL="$INSTALL_DIR/scepclient"
SERVER_URL="${SCEP_SERVER_URL}/scep/${SCEP_PROVISIONER}"
DNS_NAME="$HOSTNAME"
COMMON_NAME="$HOSTNAME"

echo "Command:"
echo "$SCEPTOOL" -private-key "$PRIVATE_KEY_FILE" -server-url "$SERVER_URL" -challenge "$SCEP_CHALLENGE" -dnsname "$DNS_NAME" -cn "$COMMON_NAME" -country "$CERT_COUNTRY" -organization "$CERT_ORGANIZATION" -ou "$CERT_OU"

echo ""

# Execute scepclient
"$SCEPTOOL" -private-key "$PRIVATE_KEY_FILE" -server-url "$SERVER_URL" -challenge "$SCEP_CHALLENGE" -dnsname "$DNS_NAME" -cn "$COMMON_NAME" -country "$CERT_COUNTRY" -organization "$CERT_ORGANIZATION" -ou "$CERT_OU"

if [ $? -ne 0 ]; then
    echo ""
    echo -e "${RED}Error: Certificate request failed!${NC}"
    echo "Please check your SCEP server URL, challenge, and root CA installation."
    exit 1
fi

# Verify certificate was created
if [ ! -f "$CERT_FILE" ]; then
    echo -e "${RED}Error: Certificate file not created${NC}"
    exit 1
fi

# Save full certificate chain
if [ -f "$FULL_CHAIN_FILE" ]; then
    rm -f "$FULL_CHAIN_FILE"
fi
cat "$ROOT_CA_FILE" > "$FULL_CHAIN_FILE"
cat "$CERT_FILE" >> "$FULL_CHAIN_FILE"

echo ""
echo "========================================"
echo -e "${GREEN}Installation Successful!${NC}"
echo "========================================"
echo ""
echo "Files created:"
echo "- Private Key: $PRIVATE_KEY_FILE"
echo "- Certificate: $CERT_FILE"
echo "- Full Chain: $FULL_CHAIN_FILE"
echo ""
echo "To import the certificate into your applications:"
echo "1. Open Keychain Access (Applications -> Utilities -> Keychain Access)"
echo "2. Import the certificate file: $CERT_FILE"
echo "3. Trust the root CA in the System keychain"
echo ""
echo "To view certificate details:"
echo "security dump-certificate $CERT_FILE"
echo ""