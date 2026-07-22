# Deployment Script
# This script helps deploy the Device Trust PKI infrastructure

#!/bin/bash

set -e

# Configuration
PROJECT_ID=${1:-$(gcloud config get-value project --quiet)}
REGION=${2:-us-central1}
TF_CLOUD_WORKSPACE=${3:-device-trust-pki}

echo "========================================="
echo "Device Trust PKI Deployment Script"
echo "========================================="
echo "Project: $PROJECT_ID"
echo "Region: $REGION"
echo "Workspace: $TF_CLOUD_WORKSPACE"
echo "========================================="
echo ""

# Check if Terraform is installed
if ! command -v terraform &> /dev/null; then
    echo "Error: Terraform is not installed. Please install Terraform 1.6 or higher."
    exit 1
fi

# Check if gcloud is installed
if ! command -v gcloud &> /dev/null; then
    echo "Error: gcloud CLI is not installed. Please install Google Cloud SDK."
    exit 1
fi

# Check if gcloud is authenticated
if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q .; then
    echo "Error: gcloud is not authenticated. Please run 'gcloud auth login'."
    exit 1
fi

# Check if Terraform Cloud CLI is installed
if ! command -v tf-cloud &> /dev/null; then
    echo "Warning: tf-cloud CLI is not installed. Using terraform init with Cloud backend."
fi

# Navigate to the directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "Current directory: $(pwd)"
echo ""

# Initialize Terraform
echo "Initializing Terraform..."
terraform init -upgrade

# Create a plan
echo ""
echo "Creating infrastructure plan..."
terraform plan -var="project_id=$PROJECT_ID" -var="region=$REGION" -out=plan.tfplan

# Ask for confirmation
echo ""
read -p "Do you want to apply this plan? (yes/no): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Applying infrastructure..."
    terraform apply plan.tfplan

    echo ""
    echo "========================================="
    echo "Deployment Complete!"
    echo "========================================="
    echo ""
    echo "Outputs:"
    terraform output -raw
else
    echo "Deployment cancelled. Plan saved as plan.tfplan."
    echo "You can apply it later with: terraform apply plan.tfplan"
fi

# Cleanup
if [[ $REPLY =~ ^[Yy]$ ]]; then
    rm -f plan.tfplan
    echo ""
    echo "Cleanup: Removed plan.tfplan"
fi

echo ""
echo "========================================="
echo "Deployment script completed."
echo "========================================="