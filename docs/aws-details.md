# AWS: Architecture, Deployment, and Enrollment

Status: **beta / testing release.** Deployed and enrollment-verified end
to end against a real AWS account - `terraform apply` succeeds, the CA
hierarchy issues valid certificates, the Connector for SCEP endpoint
serves `GetCACert` correctly, a real device enrolls successfully through
the install scripts, and the issued certificate works for TLS ClientAuth
against the mTLS test gateway. That said, this hasn't had the same
real-world mileage as the GCP side yet, and there's one deliberate,
currently-unresolved dependency worth understanding before treating this
as production-ready: getting enrollment working required two fixes to
`scepclient`, and one of them (a rejected legacy encryption algorithm)
is currently only available via a **self-maintained fork**, not an
official release. See "SCEP Client Compatibility" below for exactly what
that means, why it exists, and what would remove it.

This replaces the earlier pure design-notes version of this document now
that the two options described there have actually been decided between:
**Option A, AWS Private CA's Connector for SCEP**, was built.

## Why This Option

A general-purpose Connector for SCEP gives you a SCEP URL and a static
challenge password with no server to run - no EC2 instance, no Docker
container, no step-ca config, no custom load balancer path-restriction rule.
AWS runs the SCEP protocol implementation, CA communication, and challenge
enforcement itself. See the original comparison against running step-ca on
AWS Private CA (still relevant background, kept below) for why this was
chosen over that alternative.

## Directory Layout

```
aws/
  versions.tf       # provider requirements (aws, awscc, tls) + provider blocks
  main.tf            # wires all modules together
  variables.tf
  outputs.tf
  modules/
    network/         # minimal public VPC, only used by mtls_test_gateway
    root_ca/          # AWS Private CA root (self-signed, GENERAL_PURPOSE)
    intermediate_ca/  # AWS Private CA subordinate, signed by root_ca
    connector_scep/   # awscc_pcaconnectorscep_connector + challenge
    mtls_test_gateway/ # EC2 + nginx, ssl_verify_client on
```

This is a **separate Terraform root** from the GCP config at the repository
root - separate state, separate `terraform init`, deployed and destroyed
independently. Run all commands below from inside `aws/`.

## Prerequisites

- Terraform >= 1.0
- AWS CLI v2, configured with credentials (`aws configure`, SSO, or env
  vars) for the account you want this deployed into
- `bash` and `jq` on whatever machine runs `terraform apply` - required by
  the `connector_scep` module's challenge-password retrieval (see below),
  not by the deployed infrastructure itself
- IAM permissions for whatever principal runs `terraform apply`. A scoped,
  non-root IAM user was used for this deployment rather than root or
  `AdministratorAccess`, which surfaced the full real requirement -
  narrower than a first guess would suggest, but wider than just the
  obvious per-service actions:
  - `acm-pca:*` (root/intermediate CA creation, signing, activation)
  - `pca-connector-scep:*` (connector, challenge, `GetChallengePassword`)
  - `cloudformation:CreateResource`/`GetResource`/`UpdateResource`/`DeleteResource`/`ListResources`/`CancelResourceRequest`/`GetResourceRequestStatus` -
    **required and easy to miss**: `awscc` provider resources (the SCEP
    connector and challenge) are implemented via AWS Cloud Control, so the
    calling principal needs `cloudformation:*Resource` permissions on top
    of the `pca-connector-scep:*` permissions, or every `awscc_*` resource
    fails with an `AccessDeniedException` naming `cloudformation:CreateResource`
    rather than anything SCEP-specific.
  - `ram:*` - **required**: see "Sharing the CA with Connector for SCEP"
    below. Without this, connector creation fails with
    `PRIVATECA_ACCESS_DENIED`.
  - `ec2:*`, `secretsmanager:*`
  - `iam:CreateRole`/`DeleteRole`/`GetRole`/`PutRolePolicy`/`DeleteRolePolicy`/`GetRolePolicy`/`AttachRolePolicy`/`DetachRolePolicy`/`ListAttachedRolePolicies`/`ListRolePolicies`/`ListInstanceProfilesForRole`/`CreateInstanceProfile`/`DeleteInstanceProfile`/`GetInstanceProfile`/`AddRoleToInstanceProfile`/`RemoveRoleFromInstanceProfile`/`TagRole`/`PassRole`
    (the mTLS gateway's instance role and profile)
  - `sts:GetCallerIdentity`
  - Optional, only needed for the kind of remote verification this doc's
    testing section describes, not for deployment itself:
    `ssm:DescribeInstanceInformation`/`SendCommand`/`GetCommandInvocation`/`ListCommandInvocations`/`StartSession`/`TerminateSession`

## How AWS Private CA Differs From Google Cloud CAS Here

Worth knowing before reading the modules, since neither is a bug, both are
just how each API works:

- **Subordinate signing is manual.** GCP's `subordinate_config` auto-chains
  a subordinate CA to its parent. AWS Private CA does not - the subordinate
  CA resource is created in a `PENDING_CERTIFICATE` state, and
  `modules/intermediate_ca` has to explicitly take its CSR, sign it with the
  root CA (`aws_acmpca_certificate`), and install the signed certificate
  plus the full chain back onto it (`aws_acmpca_certificate_authority_certificate`)
  before it's usable. Same two-step "sign then activate" pattern is used for
  the root CA itself (self-signed) and for the mTLS gateway's server cert.
- **No permanent name reservation, but a pending-deletion window instead.**
  GCP permanently reserves CA pool/CA/certificate/template names after
  deletion, forcing new names on every destroy/rebuild cycle. AWS Private CA
  has no equivalent naming collision - CAs are addressed by auto-generated
  ARN, not a name you choose - but deleting one enters a mandatory
  `permanent_deletion_time_in_days` (7-30, set to 7 here) pending-deletion
  window before AWS purges it for good. This does **not** block
  `terraform destroy` from succeeding; it only affects how long the CA sits
  in a recoverable, non-billed state afterward.
- **The challenge password isn't a normal resource attribute.**
  `awscc_pcaconnectorscep_challenge` only exposes `challenge_arn`/`id` - the
  actual plaintext password is retrieved via a separate `GetChallengePassword`
  API call, repeatable, not a one-time reveal. There's no native Terraform
  resource for that read, so `modules/connector_scep` uses a `data "external"`
  block that shells out to `aws pca-connector-scep get-challenge-password`
  (the wrapper script is `modules/connector_scep/scripts/get-challenge-password.sh`)
  to surface it as `scep_challenge_password`, the same way
  `random_password.scep_challenge` does on the GCP side.
- **The SCEP URL is a complete path, not a bare domain.** GCP's SCEP URL is
  `https://<gateway-ip>/scep/<provisioner>` - the install scripts build that
  path themselves from `SCEP_SERVER_URL` + `SCEP_PROVISIONER`. AWS's
  connector endpoint comes back already complete (something like
  `https://<id>.<region>.pca-connector-scep.amazonaws.com/<account>-<connector-id>/<uuid>`).
  Appending `/scep/<provisioner>` to that would break it. All three install
  scripts now accept a `SCEP_FULL_URL` (`-ScepFullUrl` for PowerShell)
  override that's used verbatim instead - see the main Readme's Certificate
  Enrollment section.
- **Secrets Manager secrets can be reused immediately.** The mTLS gateway's
  server-key secret is created with `recovery_window_in_days = 0`, so
  destroying and recreating it doesn't hit the kind of naming limbo GCP's
  CA pools do - deliberately chosen for the same repeated
  destroy/rebuild-during-testing workflow that shaped several GCP-side
  decisions.

## Deploying

```bash
cd aws
terraform init
terraform plan -var="region=us-east-1"
terraform apply -var="region=us-east-1"
```

Or set `region` (and anything else, see `variables.tf`) in a
`terraform.tfvars` file instead.

### Sharing the CA with Connector for SCEP (required, not automated)

Connector for SCEP creation will fail with `PRIVATECA_ACCESS_DENIED` unless
the intermediate CA has first been shared with the `pca-connector-scep`
service principal via AWS RAM. This is confirmed from AWS's own setup
documentation, not something specific to this Terraform - it's a real
prerequisite for the underlying service, not a bug here. Terraform's
`aws_ram_principal_association` resource explicitly does **not** support
service principals (only AWS account IDs and Organization/OU ARNs), so this
has to be a one-time CLI step rather than a managed resource:

```bash
INTERMEDIATE_CA_ARN=$(terraform output -raw intermediate_ca_arn)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

aws ram create-resource-share \
  --region us-east-1 \
  --name device-trust-connector-scep-share \
  --permission-arns arn:aws:ram::aws:permission/AWSRAMBlankEndEntityCertificateAPICSRPassthroughIssuanceCertificateAuthority \
  --resource-arns "$INTERMEDIATE_CA_ARN" \
  --principals pca-connector-scep.amazonaws.com \
  --sources "$ACCOUNT_ID"
```

Do this once, after the intermediate CA exists (`terraform apply` up to
that point) and before the `connector_scep` module's resources apply
successfully. If you destroy and recreate the intermediate CA, the share
needs to be recreated against the new CA ARN.

After `apply`, pull the values you need for enrollment - the same shape as
the GCP `terraform output` list in the main Readme, just from this
directory's state:

```bash
terraform output -raw scep_endpoint_url            # complete SCEP URL, use as SCEP_FULL_URL
terraform output -raw scep_challenge_password       # SCEP shared secret
terraform output -raw root_ca_certificate > root-ca.crt
terraform output -raw mtls_gateway_url              # optional, for the mTLS test
```

### Enrolling against this instead of the GCP endpoint

Same three install scripts, just point them at `SCEP_FULL_URL` instead of
`SCEP_SERVER_URL`/`SCEP_PROVISIONER`, and set the encryption algorithm to an
AES variant (see "SCEP Client Compatibility" below for why this is
required and why the scripts fetch `scepclient` from a fork rather than
upstream):

```bash
export SCEP_FULL_URL="$(terraform output -raw scep_endpoint_url)"
export SCEP_CHALLENGE="$(terraform output -raw scep_challenge_password)"
export ROOT_CA_FILE_SRC="./root-ca.crt"
export SCEP_ENCRYPTION_ALGO="AES-256-CBC"
export MTLS_GATEWAY_URL="$(terraform output -raw mtls_gateway_url)"  # optional
sudo -E ./install-macos.sh
```

```powershell
.\install-windows.ps1 `
  -ScepFullUrl "$(terraform output -raw scep_endpoint_url)" `
  -Challenge "$(terraform output -raw scep_challenge_password)" `
  -RootCaFile ".\root-ca.crt" `
  -EncryptionAlgo "AES-256-CBC" `
  -MtlsGatewayUrl "$(terraform output -raw mtls_gateway_url)"
```

The first enrollment attempt is expected to fail with a `certificate
expired` message and then succeed automatically on an internal retry 15
seconds later - see "SCEP Client Compatibility" below, this is normal
AWS-side behavior the scripts already handle, not something to
troubleshoot.

## Cleanup

```bash
terraform destroy
```

No deletion-protection flag to flip first (unlike the GCP side) - the CA
modules here don't set one. `permanent_deletion_time_in_days = 7` means the
CAs enter their pending-deletion window immediately; the destroy itself
completes without waiting on it.

## What Was Verified End to End

Against a real deployment (`us-east-1`, a dedicated scoped IAM user, not
root):

- **CA hierarchy**: root and intermediate CA created and activated
  correctly; `aws acm-pca issue-certificate` against the intermediate
  produces a certificate chaining correctly to both.
- **Connector for SCEP's `GetCACert`** returns the correct three-certificate
  chain (SCEP RA certificate, signed by the intermediate; intermediate,
  signed by the root; root, self-signed) via a plain unauthenticated HTTPS
  request to `scep_endpoint_url`.
- **The mTLS test gateway** correctly rejects requests with no client
  certificate (`400`) and correctly accepts a certificate issued directly
  from the intermediate CA, returning
  `mTLS authentication successful. Verify: SUCCESS` with the correct client
  DN echoed back - confirmed via `openssl s_client` (not `curl`; see the
  Windows Schannel note below) directly against the gateway's public IP.
  This also confirms the server certificate's default template
  (`EndEntityCertificate/V1`, no `api_passthrough` override) works fine for
  TLS server use - the earlier concern about needing an explicit
  `serverAuth` EKU override turned out not to be necessary.
- The `awscc` provider's `connector_arn` and `endpoint` attributes populate
  correctly after apply, and the resources behaved as documented.

**Windows-specific note, not AWS-specific**: Windows' native `curl`
(Schannel backend) cannot use plain PEM files via `--cert`/`--key` - the
same limitation hit during GCP testing. `openssl s_client` (bundled with
Git for Windows) works directly against PEM files and was used for the
mTLS verification above instead.

## SCEP Client Compatibility (Working, via a Soft Blocker)

`install-macos.sh`/`install-windows.ps1`/`install-windows.bat` use
`micromdm/scep`'s `scepclient` to actually speak the SCEP protocol.
Upstream `scepclient` failed to enroll against AWS's Connector for SCEP
outright - two separate issues, both now understood and worked around.
**Enrollment genuinely works today**, but Issue 1's fix depends on
infrastructure (a fork we maintain ourselves) that this project didn't
previously need to maintain, which is the main reason the AWS path is
labeled beta rather than production-ready. Read on for exactly what that
dependency is and what would remove it.

### Issue 1: DES-CBC is rejected

`scepclient` hardcodes the SCEP `PKIOperation` request's CMS
`EnvelopedData` encryption to DES-CBC (`smallstep/pkcs7`'s package-level
`ContentEncryptionAlgorithm` default), with no flag to override it and no
`GetCACaps`-based negotiation. AWS Private CA's Connector for SCEP rejects
DES-CBC outright:

```
ValidationException: Unsupported algorithm: 1.3.14.3.2.7.
```

(That OID is DES-CBC.)

**Fix**: we maintain a fork of `micromdm/scep` at
[sleventyeleven/scep](https://github.com/sleventyeleven/scep), branch
`add-encryption-algo-flag`, adding a single `-encryption-algo` flag
(`DES-CBC`, `AES-128-CBC`, or `AES-256-CBC`; default `DES-CBC`, so it's a
drop-in replacement with no behavior change for the GCP path). All three
install scripts now download `scepclient` from this fork's release
(`v2.3.0-encryption-algo-test1`) instead of upstream, and pass
`-encryption-algo` through a new `SCEP_ENCRYPTION_ALGO` /
`-EncryptionAlgo` / `ENCRYPTION_ALGO` variable (default `DES-CBC`, set to
`AES-256-CBC` for AWS - see the enrollment examples above).

**Upstream status**: after building this, we found
[community PR #252](https://github.com/micromdm/scep/pull/252) already
open on `micromdm/scep` adding equivalent (and more complete - it also
supports GCM modes and documents the flag in `README.md`) functionality.
We closed our own PR (#253) as redundant rather than duplicate the
maintainer's review effort. **We're tracking #252**: if/when it merges,
switch the install scripts back to the official `micromdm/scep` release
and drop the fork dependency entirely. If it doesn't merge (or stalls),
we'll maintain `sleventyeleven/scep` as the ongoing source for
`scepclient` in this project - either way, no action is needed from
install script users beyond updating the download URL once a decision is
made.

### Issue 2: AWS rejects a request submitted too soon after CSR generation

Independent of the algorithm, AWS's Connector for SCEP can reject a
`PKIOperation` request with:

```
ValidationException: The certificate included in the request is expired.
```

This is not a real expiration - confirmed by direct investigation (the
self-signed "SCEP SIGNER" certificate's actual `notBefore`/`notAfter`
dates were inspected directly and were fine; the client's clock was
cross-checked against the Connector's own HTTP `Date` header and agreed to
within a few seconds). **Resubmitting the identical cached request
(same CSR, same self-signed signer certificate, not regenerated) reliably
succeeds once some time has passed** - confirmed repeatedly, anywhere from
~9 seconds to 2+ minutes later.

This isn't a guaranteed "always fails the first time" behavior - it
correlates with how little wall-clock time elapses between generating the
self-signed signer certificate and actually submitting the `PKIOperation`.
`install-windows.ps1`/`.bat` reach that submission almost immediately
(cert-store operations are fast and non-interactive), and reliably hit
this on the first attempt. `install-macos.sh` does several interactive
keychain operations (trusting the root and intermediate CA, each needing a
password/Touch ID prompt) *before* it calls `scepclient` at all - by the
time the real human at the keyboard has clicked through those, enough time
has usually already passed that the first SCEP attempt succeeds outright,
with no retry needed.

**Fix**: all three install scripts retry once automatically if the first
attempt fails, waiting 15 seconds and reusing the same cached
`csr.pem`/`self.pem`/key rather than regenerating them. On Windows this
retry reliably fires; on macOS it's usually a no-op since the interactive
prompts already provided enough of a delay. Harmless either way, and a
no-op against step-ca/GCP too (a genuine failure there just fails the same
way twice).

### Net result

Both fixes verified together against a real deployment: first attempt
fails with the transient "expired" error as expected, the automatic retry
15 seconds later succeeds (`pkiStatus=SUCCESS`), and the issued certificate
was confirmed to work for TLS ClientAuth against the mTLS test gateway.
AWS Connector for SCEP is now **enrollment-verified**, not just
infrastructure-verified, with this repository's install scripts.

## Alternative Considered: step-ca on AWS Private CA

Kept for reference - this is the option that was *not* built, and why.

This would look most like the existing GCP module
(`modules/stepca_container`), unchanged in shape: step-ca on an EC2
instance as a Registration Authority, holding the SCEP provisioner,
delegating signing to AWS Private CA instead of Google Cloud CAS.

The catch: step-ca's CloudCAS integration for GCP is first-party and
production-proven (this whole project runs on it). Its AWS Private CA
equivalent is part of Smallstep's newer ACME RA product line and was, as of
the original research here, still described as early access rather than a
generally available, documented `awscas`-style authority type comparable to
`cloudCAS`. Building this would mean depending on an early access
integration, or writing a custom signer against the AWS Private CA
`IssueCertificate`/`GetCertificate` APIs directly - either materially more
fragile than Connector for SCEP's fully managed path.

**When this option would still be worth building**: if a genuine
requirement shows up for one uniform RA layer (step-ca) across every cloud,
so provisioner config, templates, and operational tooling are identical
regardless of which cloud's CA is doing the actual signing. That
consistency has real value for a multi-cloud fleet; it just costs more to
build and maintain than the connector does on AWS alone, and nothing here
blocks building it later if that need materializes.
