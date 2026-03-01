# Device Trust PKI Infrastructure

This repository contains a comprehensive Terraform configuration for deploying a secure, scalable PKI infrastructure using Google Cloud Private CA and step-ca for device trust certificates.

## Architecture Overview

The infrastructure consists of the following components:

1. **Network Module** - Creates a VPC network with private subnets and VPC connectors for Cloud Run
2. **CA Pool Module** - Sets up shared Enterprise-tier CA pools for both root and intermediate CAs
3. **Root CA Module** - Creates a root Certificate Authority with 10-year lifetime
4. **Intermediate CA Module** - Creates a subordinate CA (5-year lifetime) for issuing certificates
5. **Certificate Template Module** - Defines SCEP-compatible certificate templates with proper extensions
6. **step-ca Container Module** - Deploys step-ca as a Cloud Run service
7. **SCEP Endpoint Module** - Creates a secure SCEP endpoint with load balancing
8. **Main Configuration** - Orchestrates all modules and manages IAM roles

## Features

- **Enterprise-grade PKI**: Uses Google Cloud Private CA with root and intermediate CAs
- **SCEP Support**: Compatible with SCEP clients for certificate enrollment
- **Cloud Native**: Deployed on Google Cloud using Cloud Run, Cloud Load Balancing, and VPC connectors
- **Highly Available**: Auto-scaling Cloud Run instances and load-balanced SCEP endpoints
- **Secure by Design**: Deletion protection, proper IAM roles, and network isolation
- **ACME Integration**: Optional ACME challenge support for Let's Encrypt integration

## Prerequisites

- Google Cloud project with Terraform Cloud credentials
- Admin permissions for the project
- Google Cloud SDK installed
- Terraform configured for Terraform Cloud

## Quick Start

### 1. Initialize the Terraform configuration

```bash
terraform init
```

### 2. Configure variables

Edit `variables.tf` to set your configuration:

```hcl
variable "project_id" {
  default = "your-project-id"
}

variable "region" {
  default = "us-central1"
}

variable "network_name" {
  default = "device-trust-network"
}
```

### 3. Apply the configuration

```bash
terraform plan
terraform apply
```

## Module Details

### Network Module

Creates a VPC network with:
- Private subnets for isolated networking
- VPC connector for Cloud Run connectivity
- Network load balancer

**Outputs:**
- `vpc_self_link` - Self-link of the VPC network
- `subnet_self_link` - Self-link of the subnet
- `vpc_connector_self_link` - Self-link of the VPC connector

### CA Pool Module

Configures shared CA pools for:
- Root CA pool (Enterprise tier)
- Intermediate CA pool (Enterprise tier)

**Outputs:**
- `root_ca_pool_id` - ID of the root CA pool
- `ca_pool_id` - ID of the intermediate CA pool

### Root CA Module

Creates a root Certificate Authority with:
- 10-year certificate lifetime
- Deletion protection
- Optional publishing to Cloud Storage

**Outputs:**
- `root_ca_pem_certificate` - PEM-encoded root CA certificate
- `root_ca_pem_private_key` - PEM-encoded private key (if generated)
- `root_ca_issuer_url` - Issuer certificate URL

### Intermediate CA Module

Creates a subordinate CA with:
- 5-year certificate lifetime
- Parented by root CA
- Deletion protection

**Outputs:**
- `intermediate_ca_pem_chain` - Complete PEM-encoded certificate chain
- `intermediate_ca_pem_certificate` - PEM-encoded intermediate CA certificate
- `intermediate_ca_pem_private_key` - PEM-encoded private key (if generated)

### Certificate Template Module

Defines SCEP-compatible certificate templates with:
- Server authentication
- Client authentication
- Code signing
- Email protection
- Smart card logon

**Outputs:**
- `certificate_template_id` - ID of the certificate template
- `certificate_template_name` - Name of the certificate template

### step-ca Container Module

Deploys step-ca as a Cloud Run service with:
- Auto-scaling
- VPC connector connectivity
- Custom environment variables
- Health checks

**Outputs:**
- `stepca_url` - URL for step-ca service
- `stepca_host` - Host for step-ca service
- `service_account_email` - Email of the step-ca service account

### SCEP Endpoint Module

Creates a secure SCEP endpoint with:
- Cloud Load Balancing
- Auto-scaling instances
- Health checks
- Network firewall rules

**Outputs:**
- `scep_url` - URL for SCEP endpoint
- `scep_ip_address` - IP address of the SCEP endpoint

## Certificate Enrollment

### Using SCEP

Configure your SCEP clients with:

```
SCEP Server: https://<scep-endpoint-ip>/scep
Challenge: simple
CA Certificate: <intermediate-ca-certificate>
```

### Using step-ca CLI

```bash
# Import the root CA
step ca root root.crt --force

# Import the intermediate CA
step ca import intermediate.crt intermediate.key

# Generate a certificate
step ca certificate --profile web myhost.example.com myhost.crt myhost.key
```

## Security Considerations

- **Deletion Protection**: All CA certificates have deletion protection enabled
- **IAM Roles**: Proper role separation for CA operations
- **Network Isolation**: Private VPC networks and VPC connectors
- **Key Management**: Strong key algorithms and sizes
- **Certificate Expiry**: Configurable lifetimes with automatic renewals

## Troubleshooting

### Access Denied Errors

Ensure the step-ca service account has proper IAM roles:
- `roles/privateca.issuer` for root CA
- `roles/privateca.templateUser` for intermediate CA

### Certificate Enrollment Failures

- Verify the CA pool and CA are activated
- Check the SCEP endpoint is running
- Ensure the correct CA certificate is configured

### Network Connectivity Issues

- Verify VPC connector connectivity
- Check firewall rules for SCEP access
- Ensure proper subnet configuration

## Cleanup

To remove all resources:

```bash
terraform destroy
```

**Note:** This will delete all CA certificates and their associated data. Exercise caution.

## Support

For issues or questions, please refer to:
- [Google Cloud Private CA Documentation](https://cloud.google.com/private-ca/docs/overview)
- [step-ca Documentation](https://smallstep.com/docs/step-ca/)
- [Terraform Cloud Documentation](https://www.terraform.io/docs/cloud/index.html)

## License

This configuration is provided as-is for educational and commercial use.