# Device Trust PKI Infrastructure

This repository contains a Terraform configuration for deploying a PKI
infrastructure using Google Cloud Private CA (CAS) and step-ca for device
trust certificate enrollment over SCEP.

## Architecture Overview

1. **Network Module** - VPC, subnet, and a Cloud NAT gateway (outbound
   internet for VMs with no external IP)
2. **CA Pool Module** - Shared Enterprise-tier CA pools for the root and
   intermediate CAs, plus their IAM bindings (granted at the pool level -
   Private CA has no per-CertificateAuthority IAM resource)
3. **Root CA Module** - A self-signed root CA (offline in spirit: nothing is
   granted standing access to it)
4. **Intermediate CA Module** - A subordinate CA signed by the root
5. **Certificate Template Module** - A GCP CertificateTemplate resource
   (currently provisioned but not consumed by the SCEP issuance path - see
   Known Limitations)
6. **step-ca Container Module** - step-ca running as a Docker container on a
   Compute Engine VM (no external IP), configured as a Registration Authority
   (`authority.type = cloudCAS`) that delegates all signing to the
   intermediate CA above. step-ca terminates its own TLS, which is why it
   runs on a VM rather than Cloud Run (Cloud Run always terminates TLS at its
   edge and forwards plaintext HTTP internally - incompatible with step-ca,
   which has no way to disable its own TLS termination)
7. **SCEP Gateway Module** - An external HTTPS load balancer in front of the
   step-ca VM, restricted by URL map path rule so only `/scep/*` is publicly
   reachable; every other path (step-ca's admin/API surface) 403s via a
   deny-by-default empty-bucket backend. The client-facing TLS certificate is
   self-issued off the intermediate CA (no public domain required); the
   backend hop to the VM is re-encrypted HTTPS that GCP does not validate the
   certificate chain for
8. **mTLS Test Gateway Module** - A small public nginx VM requiring TLS
   client certificate authentication (`ssl_verify_client on`), used to prove
   an enrolled device certificate actually works for ClientAuth and not just
   that it was issued. Gated behind `enable_mtls_test_gateway` (default
   `true`) - see the "mTLS Test Gateway" section below
9. **Main Configuration** - Orchestrates all modules, enables required GCP
   APIs, and manages cross-module IAM

## Features

- **Enterprise-grade PKI**: Google Cloud Private CA root + intermediate CA
- **SCEP enrollment**: step-ca as a cloudCAS Registration Authority in front
  of the intermediate CA
- **Path-restricted public access**: only the SCEP endpoint is exposed
  through the load balancer, not step-ca's full API
- **Least privilege**: the root CA pool has no standing IAM access by
  default; the step-ca service account only holds what it actually uses
- **ACME DNS validation**: optional, for Let's Encrypt-style domain
  validation flows unrelated to the SCEP path

## Prerequisites

- A Google Cloud project and an authenticated `gcloud` session
- Terraform >= 1.0
- `gcloud` CLI (also used for `gcloud compute ssh --tunnel-through-iap` if
  you need to inspect the step-ca VM directly)

## Quick Start

```bash
terraform init
terraform plan -var="project_id=<your-project-id>"
terraform apply -var="project_id=<your-project-id>"
```

Or set `project_id` (and anything else you want to override) in a
`terraform.tfvars` file instead of passing `-var` every time. See
`variables.tf` for the full list of configurable inputs and their defaults.

## Certificate Enrollment

After `apply`, pull the values you need:

```bash
terraform output -raw scep_endpoint_url          # https://<gateway-ip>/scep/device-trust-scep
terraform output -raw scep_challenge_password     # SCEP shared secret
terraform output -raw root_ca_certificate > root-ca.crt
```

**`install-windows.ps1` and `install-macos.sh` derive the intermediate CA
automatically** - it's not published anywhere by default, but the SCEP
server's own `GetCACert` response (the same operation `scepclient` itself
calls first, and already public - no additional trust needed to fetch it)
contains the full chain, so both scripts parse the intermediate cert out of
that PKCS#7 response themselves when `-IntermediateCaFile`/`-IntermediateCaUrl`
(or `INTERMEDIATE_CA_FILE_SRC`/`INTERMEDIATE_CA_URL`) aren't given. Only
fall back to
`terraform output -raw intermediate_ca_certificate > intermediate-ca.crt`
plus that flag/variable if you're pointing a script at a different SCEP
server that doesn't return the same thing (not yet implemented for
`install-windows.bat`, which still requires it to be supplied explicitly if
you want the full chain bundled).

### Using the install scripts

`install-windows.ps1` / `install-windows.bat` / `install-macos.sh` download
`micromdm/scep`'s `scepclient`, install the root CA into the OS trust store,
and request a device certificate over SCEP. They take the SCEP server URL,
provisioner name, challenge, and root CA (as a URL or a local file) as
environment variables or (PowerShell only) named parameters - see
`config.sh` for the full variable list and where each value comes from.

**These scripts should be treated as a best-effort starting point, not a
fully tested, hardened deliverable.** `install-windows.ps1` and
`install-windows.bat` have each been run end-to-end against a real
deployment (cert issuance, cert-store install, and the mTLS gateway test all
verified live); the macOS variant has had several rounds of real-machine
feedback fixed (broken/outdated `scepclient` download URLs, a missing
`-certificate` flag, an amd64/arm64 CPU-architecture bug, `sh`-vs-`bash`
output glitches, moving both the root CA trust setting and the device
certificate/key from loose files into the invoking user's own login
keychain, and automatic intermediate CA derivation). **Real-machine testing
confirmed that step requires interactive authentication (password or Touch
ID)** - see Known Limitations below, this isn't a bug to fix, just something
to expect.

**The root CA file/URL is not optional.** `scepclient` verifies the SCEP
server's own TLS certificate before it will enroll at all, and each script's
first real step is installing that same root CA into the OS trust store -
without it, enrollment fails at the very first request, before any
certificate-specific logic even runs. Always pass it, either as a local file
(`root-ca.crt`, exported via `terraform output -raw root_ca_certificate >
root-ca.crt` as shown above) or a URL if you're hosting the PEM somewhere.

Example (Windows PowerShell - run elevated, `-RootCaFile` is bound to env var
`ROOT_CA_FILE`, **not** `ROOT_CA_FILE_SRC`):

```powershell
.\install-windows.ps1 `
  -ScepServerUrl "https://$(terraform output -raw scep_gateway_ip)" `
  -Provisioner "device-trust-scep" `
  -Challenge "$(terraform output -raw scep_challenge_password)" `
  -RootCaFile ".\root-ca.crt" `
  -MtlsGatewayUrl "$(terraform output -raw mtls_gateway_url)"
```

Example (Windows Batch - run from an elevated `cmd.exe`; env-var only, no
named parameters; uses `ROOT_CA_FILE_SRC` like macOS, not `ROOT_CA_FILE`):

```bat
set SCEP_SERVER_URL=https://<scep-gateway-ip>
set SCEP_PROVISIONER=device-trust-scep
set SCEP_CHALLENGE=<scep-challenge-password>
set ROOT_CA_FILE_SRC=.\root-ca.crt
set MTLS_GATEWAY_URL=<mtls-gateway-url>
install-windows.bat
```

Example (macOS):

```bash
export SCEP_SERVER_URL="https://$(terraform output -raw scep_gateway_ip)"
export SCEP_PROVISIONER="device-trust-scep"
export SCEP_CHALLENGE="$(terraform output -raw scep_challenge_password)"
export ROOT_CA_FILE_SRC="./root-ca.crt"
export MTLS_GATEWAY_URL="$(terraform output -raw mtls_gateway_url)"  # optional
chmod +x install-macos.sh
sudo -E ./install-macos.sh
```

The certificate and its private key end up in **your own login keychain**
(not the System keychain, and not loose files) - that's what Safari/Chrome
consult when a gateway responds with a TLS ClientAuth challenge. The root
*and* intermediate CA are both explicitly trusted there too (not just
bundled into the device cert's PKCS#12), for a cleaner trust indicator in
Keychain Access and browsers - each is only trusted (and only prompts for
your password/Touch ID) if it isn't already, so a renewal run doesn't
re-trigger those prompts for CAs that haven't changed. Run
`security find-identity -v -p ssl-client` to confirm the device cert is
there and usable.

On a renewal, any *previous* device certificate(s) are removed from the
keychain (matched by common name, which is always the hostname): every
matching certificate's SHA-256 hash is captured *before* the new one is
imported, then each of those exact hashes is deleted once the new import
succeeds - not before, so a failed renewal doesn't leave the device with no
usable certificate at all. Without this, a renewal would leave two (or
more) near-identical entries side by side - same name, different
expiration - which is confusing when a browser's ClientAuth certificate
picker shows all of them as options.

Getting here took two false starts, both eventually traced to the same
actual cause via a real working command example from live testing: **the
keychain must be passed as a bare trailing argument to
`find-certificate`/`delete-certificate`, not via a `-k <keychain>` flag** -
`-k` is accepted (and works) by `verify-cert` elsewhere in this script, but
appears to be silently rejected or simply wrong for these two specific
subcommands, causing the whole lookup/delete to fail with no visible
error. That single fix resolved both earlier symptoms:

- The first attempt (hash-capture via `-Z`, delete by exact hash after
  import) looked correct but never actually found or removed anything -
  attributed at the time to `-a` only returning the first match.
- A loop-based `delete-certificate -c` (deleting by name repeatedly until
  no matches remained) was tried next, on the theory that both
  `find-certificate -a` and `delete-certificate -c` only ever act on the
  first match - it didn't work either, for the same underlying `-k` reason.

Confirmed directly: `security find-certificate -a -Z -c "<hostname>" -p
<keychain>` (no `-k`) does return *every* matching certificate, and
`security delete-certificate -Z <hash> <keychain>` (again, no `-k`)
correctly removes exactly the one with that hash. The script now uses the
SHA-256 hash specifically (not SHA-1) to match that confirmed-working
example exactly. Because the capture step correctly finds *every* match,
one corrected run also sweeps up any duplicates left over from earlier,
non-working versions of this script - not just future ones.

**A cosmetic macOS quirk to expect after cleanup:** the superseded
certificate can still show up in Keychain Access afterward, "ghosted"
(grayed out, no private key alongside it), rather than disappearing
outright. This is harmless and doesn't affect anything: `scepclient`
reuses the same private key across every renewal on macOS (there's no
`-KeyProtection`-style Delete mode here, unlike Windows), so there's only
ever one actual private key object in the keychain - Keychain Access pairs
it with whichever certificate is current, and the old certificate we just
deleted is left displayed as a bare certificate with no matching key.
Without a private key, it isn't a usable identity, so it's **not** offered
as a ClientAuth option in the browser's certificate picker either - the
ghosting is purely a Keychain Access display artifact. If it bothers you,
it can be removed manually from Keychain Access, but there's no functional
reason to.

`sudo -E` (not plain `sudo`) is required - the script needs root to write to
`/usr/local/bin`, but plain `sudo` resets the environment by default,
silently dropping every `SCEP_*`/`ROOT_CA_*` variable exported above and
falling back to the script's placeholder defaults (`step-ca.example.com`,
`poc_devicetrust`, etc.) without any error. Everything keychain- and
certificate-related runs as *your* user, not root, via `$SUDO_USER` -
including `scepclient` itself, since its own TLS verification of the
gateway's certificate consults whichever keychain belongs to the calling
process's user, and root has no login keychain of its own. Certificate
working files live in `~/.device-trust` (not `/etc`) for the same reason -
that process needs to write there without being root.

### Windows: certificate store install and the `-KeyProtection` trade-off

On Windows, the issued device certificate is packaged into a PFX (via
smallstep's own `step` CLI, fetched alongside `scepclient`) and imported into
`Cert:\CurrentUser\My` with `certutil -importpfx ... NoExport` - "user space",
per the intended use case (TLS ClientAuth for conditional-access policies and
gateways, as described in
[Identity Provider Empowered Device Trust](https://hackersvanguard.com/identity-provider-empowered-device-trust/)
and
[Creating a Simple Device Trust Gateway](https://hackersvanguard.com/creating-a-simple-device-trust-gateway-using-device-certificates/)).

**What "non-exportable" does and doesn't mean here:** `NoExport` blocks casual
re-export via Windows' own certificate UI/cmdlets. It is *not* the same
guarantee as a hardware/CNG-backed non-exportable key (which would require
generating the key inside Windows' own crypto store from the start).
`scepclient` generates the key in software and writes it to a plain file
before it's imported - by the time `NoExport` is applied, the raw key
material has already existed outside Windows' control, if only briefly.

After import, the script has to decide what to do with that loose key file
(`certs\client.key`) - this is the `-KeyProtection` flag
(`KEY_PROTECTION` env var for the `.bat`), default `Delete`:

| Mode | Behavior | Trade-off |
|---|---|---|
| `Delete` (default) | Deletes `client.key`/`client.crt` after import | Matches "non-exportable" most literally, but the next renewal has no key to reuse - `scepclient` generates a **brand new key and requests a brand new certificate** every time, which is a full re-enrollment, not a lightweight renewal |
| `RestrictPermissions` | Keeps `client.key` in place but locks its ACL to `SYSTEM` + `Administrators` (`icacls`), stripping the standard user's own read access | Lets `scepclient` reuse the same key on the next run (true same-key renewal, cheaper) - but an admin-level actor (or this script itself, which already requires admin) can still read the key file, so it's a weaker guarantee than `Delete` |

**Why this matters for cost, not just security:** Google Cloud Private CA
(CAS) bills **per certificate-issuance operation**, on top of the Enterprise
pool's own monthly base fee. `Delete`'s forced full re-enrollment means a new
CAS signing operation on every single renewal cycle; `RestrictPermissions`
avoids that recurring cost by reusing the same key/cert lineage across
renewals, at the cost of a weaker (ACL-based, not cryptographic) protection
guarantee on the loose key file. Pick based on which you're actually
optimizing for - there's no default that's strictly better on both axes.

### mTLS Test Gateway

`modules/mtls_test_gateway` deploys a small public nginx VM
(`enable_mtls_test_gateway`, default `true`) that requires a valid TLS client
certificate chained to the intermediate CA (`ssl_verify_client on`) and
echoes back the verification result and client DN - a minimal version of the
gateway pattern from
[Creating a Simple Device Trust Gateway](https://hackersvanguard.com/creating-a-simple-device-trust-gateway-using-device-certificates/).
It exists purely to prove an enrolled certificate actually works for
ClientAuth, not just that it was issued.

```bash
terraform output -raw mtls_gateway_url   # https://<gateway-ip>/

# No client cert -> rejected
curl -k https://<gateway-ip>/            # 400 No required SSL certificate was sent

# Valid client cert -> accepted
curl -k --cert client.crt --key client.key https://<gateway-ip>/
# mTLS authentication successful.
# Verify: SUCCESS
# Client DN: CN=...
```

`install-windows.ps1` (`-MtlsGatewayUrl`), `install-windows.bat`
(`MTLS_GATEWAY_URL` env var), and `install-macos.sh` (same env var) all run
this exact check automatically after installing the certificate, and print
`PASS`/`FAIL`. On Windows this uses `Invoke-WebRequest -Certificate` against
the cert straight from `Cert:\CurrentUser\My`; on macOS it uses `curl
--cert`/`--key` against the loose PEM files in `~/.device-trust` (the same
cert/key content that's also in the keychain - `curl`'s `--cert`/`--key`
flags work with plain files regardless of TLS backend, which is simpler
than referencing the keychain identity directly). Note: on Windows
PowerShell 5.1, bypassing validation of the gateway's own (self-issued)
server certificate requires a compiled `Add-Type` delegate for
`ServerCertificateValidationCallback` - a plain scriptblock (`{ $true }`)
fails with "no Runspace available" because .NET invokes it on the TLS
handshake thread, which has no PowerShell runspace.

Set `enable_mtls_test_gateway = false` to skip deploying it (saves one
small VM) once you've verified enrollment works and don't need the ongoing
test target.

### Manually, with scepclient directly

```
SCEP Server: https://<scep-gateway-ip>/scep/device-trust-scep
Challenge:   terraform output -raw scep_challenge_password
CA cert:     terraform output -raw root_ca_certificate
```

## Security Considerations

- **Deletion protection** on both CAs
- **Least-privilege IAM**: the root CA pool has no standing bindings; the
  step-ca service account only holds `roles/privateca.certificateRequester`
  + `roles/privateca.viewer` on the intermediate's pool (the latter because
  step-ca's cloudCAS client calls `GetCertificateAuthority`, which
  `certificateRequester` alone doesn't cover), plus Secret Manager accessor
  on its own two secrets
- **No external IP** on the step-ca VM; reachable only via the gateway LB
  (over the internal VPC) and via IAP-tunneled SSH for operators
- **Path-restricted public surface**: only `/scep/*` is reachable from the
  internet
- **mTLS test gateway is intentionally public** (its whole purpose is to be
  reachable from wherever an enrolled device is) but only accepts requests
  presenting a certificate chained to the intermediate CA; anything else gets
  a 400 before the request is ever processed. Disable it via
  `enable_mtls_test_gateway = false` when you don't need an ongoing test
  target

## Known Limitations

- **CA lifetimes are shorter than their variable comments claim.**
  `root_ca_lifetime` (`31536000s`) is commented "10 years" but is actually
  **1 year**; `intermediate_ca_lifetime` (`15768000s`) is commented "5
  years" but is actually **~6 months**. This wasn't fixed because `lifetime`
  is immutable on `google_privateca_certificate_authority` - correcting it
  would force-recreate both CAs (a full PKI reset). Decide deliberately
  whether to reset the hierarchy now or live with the shorter real
  lifetimes and plan a rotation.
- **The certificate_template module is provisioned but not consumed** by the
  actual SCEP issuance path - step-ca's cloudCAS RA config signs directly
  against the intermediate CA and doesn't reference a GCP CertificateTemplate
  per-request. It's harmless sitting there and can be wired in later if a
  per-request policy hook is confirmed to exist, but currently does nothing.
- **Install scripts are best-effort** - see the Enrollment section above.
- **macOS keychain installation requires interactive authentication (password
  or Touch ID) - there is no fully unattended path.** Both trusting the root
  CA and importing the device certificate/key modify a keychain, and macOS
  requires interactive auth for that regardless of running as the correct
  user (not root) or passing any combination of `security` flags intended to
  suppress it. The only documented way around this is distributing the
  certificate via an MDM `.mobileconfig` profile - but enrolling a device
  into MDM management is itself an interactive, user-consented step, so it
  doesn't actually eliminate the requirement, just moves it earlier.
  `install-macos.sh` still automates everything else (download, SCEP
  enrollment, chain derivation); be at the keyboard to approve the
  prompt(s) when it runs.
- **Stale local state from before a full CA destroy/rebuild breaks the next
  run - clean it up first.** Both `install-macos.sh` and `install-windows.ps1`
  treat an existing private key/cert (`~/.device-trust/client.key` on macOS,
  `Cert:\CurrentUser\My` with `-KeyProtection RestrictPermissions` on
  Windows) as "renew this," and `scepclient` reuses that key/cert to make the
  renewal request. That's correct for renewing against the *same* CA, but if
  the whole PKI hierarchy was destroyed and recreated in between (as when
  doing a `terraform destroy`/`apply` cycle for testing, not a normal
  production event), the old cert was issued by a root/intermediate CA that
  no longer exists - the new step-ca instance has no way to validate a
  "renewal" against a CA it's never heard of, and `scepclient` fails.
  This is expected given a full CA rebuild, not a script bug: before
  re-testing against rebuilt infrastructure, remove the old state first -
  delete `~/.device-trust/` on macOS (and remove the stale identity via
  `security delete-certificate`/Keychain Access if it was already imported),
  or delete `C:\Program Files\scepclient\certs` and any matching
  `Cert:\CurrentUser\My` entry on Windows - so the script performs a genuine
  first-time enrollment against the new hierarchy instead of attempting a
  renewal.

## Troubleshooting

### `terraform apply` fails with "Failed to retrieve project, pid: , err: project: required field is not set"

`project_id` (`variables.tf`) defaults to `null`, relying on the `google`
provider falling back to `gcloud`'s Application Default Credentials for the
active project. That fallback resolves fine for the provider's own
`ConfigureProvider` step and for resources being *refreshed* from existing
state, but was observed to fail specifically for **brand-new** resource
creation in some sessions - the exact trigger wasn't pinned down, but setting
`project_id` explicitly sidesteps it entirely. Create a `terraform.tfvars`
(already gitignored) with:

```hcl
project_id = "<your-project-id>"
```

### IAM / permission denied errors

- `roles/privateca.certificateRequester` and `roles/privateca.viewer` are
  granted on the **intermediate CA's pool** (not on the CA itself - Private
  CA has no per-CertificateAuthority IAM resource, and not on the root pool,
  which intentionally has no standing access).
- If you see `GetCertificateAuthority` permission errors from step-ca's own
  logs (`gcloud compute ssh step-ca --tunnel-through-iap --command="sudo
  docker logs step-ca"`), check that the `privateca.viewer` binding exists
  on the CA pool.

### SCEP enrollment failures

- Confirm the gateway backend is healthy:
  `gcloud compute backend-services get-health scep-gateway-backend --global`
- Check step-ca's own logs over SSH (above) - a 502 from the gateway means
  the backend health check is failing, not necessarily that step-ca itself
  is broken.
- Non-SCEP paths (e.g. `/`) are expected to return 403 from the gateway -
  that's the deny-by-default routing working as intended, not a bug.

### Windows: `CertUtil: -importPFX command FAILED: 0x80070056 (ERROR_INVALID_PASSWORD)` on the PFX import

PowerShell has a real quirk: an empty string (`""`) passed directly as an
argument to a native executable can get silently dropped rather than passed
through as a zero-length argument, shifting every argument after it over by
one position. With `certutil -importpfx -p "" My <pfx> "NoRoot,..."`, that
meant certutil actually received `-p My <pfx> ...` and tried to use the
literal word `My` (meant to be the store name) as the password -
`ERROR_INVALID_PASSWORD`. Fixed by giving the PFX a real (random, throwaway)
password via `step certificate p12 --password-file`, passed identically to
`certutil -importpfx -p`. The password has no security significance - the
PFX is shredded immediately after import either way - it only needs to be
non-empty so PowerShell doesn't drop it. If you still hit this, you're on
an older copy of `install-windows.ps1` - re-download it. `install-windows.bat`
never needed this fix - plain `cmd.exe` passes empty-string arguments to
native executables correctly; the bug is PowerShell-specific. (This is a
different situation from macOS, where an empty PKCS#12 password is
actually the *right* choice - see the "browser asks for 'the temporary
password'" entry below - because bash doesn't have this argument-dropping
behavior at all.)

### macOS: `install-macos.sh: line 168: /usr/local/bin/scepclient: Bad CPU type in executable`

`scepclient`'s GitHub releases ship separate `darwin-amd64` and
`darwin-arm64` binaries. The script detects your CPU via `uname -m` and
downloads the matching one, defaulting to `arm64` for anything that isn't
explicitly `x86_64` (Apple Silicon is the forward-looking default, and
Rosetta 2 - needed to run an amd64 binary on Apple Silicon - isn't installed
by default on new Macs). If you still hit this, you're likely running an
older copy of the script from before this was fixed - re-download it.

### macOS: `SecTrustSettingsSetTrustSettings: The authorization was denied since no user interaction was possible`

This specific error means the script tried to trust a certificate
system-wide (the System keychain), which requires an interactive
authorization prompt that a script running under `sudo`/SSH has no GUI
session to display at all - a hard, headless failure. The script instead
trusts the root CA - and imports the device certificate/key - in the
**invoking user's own login keychain** (via `$SUDO_USER`, which is why
`sudo -E`, not plain `sudo`, is required). If you still hit this exact
System-keychain error, you're on an older copy of the script - re-download
it.

Note this is different from - and doesn't eliminate - the interactive
password/Touch ID prompt(s) you'll still see for the login-keychain
operations themselves. That prompt is expected (see Known Limitations
above) and needs a human present to approve it; it just isn't the same
"headless dead end" as the System-keychain error above, which cannot be
approved by anyone, ever, in a non-interactive session.

### macOS: `tls: failed to verify certificate: x509: certificate signed by unknown authority` from `scepclient`, even though the root CA install reported success

`scepclient`'s own TLS verification of the gateway's certificate consults
whichever keychain belongs to the *process's own user* - if `scepclient`
runs as root (which it would if simply invoked from within a `sudo -E`
script without stepping back down), it checks root's own trust settings,
not the ones just installed in your login keychain, and root has no login
keychain of its own to speak of. The script now runs `scepclient` itself as
`$SUDO_USER` (via `sudo -u`) rather than as root, specifically so this
lookup lands in the right keychain. If you still hit this, you're on an
older copy of the script - re-download it. This is also why certificate
working files live under `~/.device-trust` rather than `/etc/device-trust`:
that process needs to write there as your own user, not as root.

### macOS: `security: Error reading infile ...device-trust-cert.XXXXXX.p12...: Permission denied` during the final import

The device cert's PKCS#12 bundle used to be built in the default temp
directory (`mktemp -t`), which under `sudo -E` resolves to the invoking
user's own per-user `/var/folders/.../T/` path - root writing there and
`$TARGET_USER` (via `sudo -u`) reading it back don't reliably work across
that root/user boundary, even after `chmod 644`. Moving the file to
`~/.device-trust` also surfaced a second bug worth calling out separately
(see below): macOS's BSD `mktemp` doesn't reliably substitute the `X`s in a
positional template when they're followed by a literal suffix like `.p12`
(confirmed live - `step`'s own "saved as" message showed the literal,
un-substituted `XXXXXX` in the path), silently reusing the same fixed
filename across runs. Fixed by switching to `mktemp -d` (a directory
template, which doesn't have this suffix ambiguity and is already used
successfully elsewhere in the script) plus fixed filenames underneath it,
applied to every `mktemp` call in the script with that same
"prefix.XXXXXX.suffix" shape, not just this one. If you still hit this,
you're on an older copy - re-download it.

### macOS: `security: SecKeychainItemImport: MAC verification failed during PKCS12 import (wrong password?)`, even with a fresh, correct password

A separate bug from the one above (the `mktemp` fix alone doesn't resolve
this one) - `step`'s *default* PKCS#12 encoding uses modern OpenSSL 3.x
algorithms (a newer MAC, AES encryption) that macOS's own Security
framework importer doesn't support, so it fails claiming the password is
wrong when it's actually an algorithm mismatch. Confirmed directly:
`openssl pkcs12 -info` on the resulting file shows `MAC: sha1` is what's
expected, but the *default* output uses something newer. Fixed by adding
`--legacy` to the script's `step certificate p12` call, which switches to
the traditional `PBE+SHA1+RC2`/`PBE+SHA1+3DES` encoding macOS's importer
actually understands (verified the resulting file's algorithms and that it
decodes correctly with `openssl pkcs12 -legacy`). If you still hit this,
you're on an older copy - re-download it. This hasn't come up on Windows -
`certutil` there handles the modern encoding fine - so `--legacy` is
macOS-only.

### macOS: browser asks for your login password/Touch ID when using the device certificate (expected behavior, not a bug)

**Confirmed working as intended.** After running the script, quit and
restart your browser, then visit a ClientAuth-protected URL (e.g. the mTLS
test gateway): a certificate picker appears, you choose the device trust
identity, and the browser then asks for **your own macOS login
password or Touch ID** (via a standard "keychain wants to use your
confidential information" prompt) before it will actually use the private
key. This isn't the throwaway PKCS#12 password from installation leaking
through - it's the keychain's own per-use access control, and it's a
*good* thing: it means a browser (or anything else) can't silently use the
private key for a ClientAuth handshake without your consent each time,
which is exactly the point of a device-bound credential. It only prompts
once the browser process picks it up fresh, which is why a restart is
needed after (re)installing.

The PKCS#12 bundle itself is still built with a random, throwaway password
(matching Windows) purely to get it into the keychain in the first place -
that password has no bearing on the per-use prompt above, and two attempts
to give it a fixed or empty password instead were tried and abandoned along
the way, each for its own unrelated reason:

- **A truly empty password** (`step ... --no-password --insecure`, then
  `security import -P ""`) - `security import` doesn't treat an
  explicitly-empty `-P` value as "no password" the way other PKCS#12 tools
  do; the import itself fails outright.
- **A single space character** (as a middle ground) - fails even earlier:
  `step` trims/rejects a whitespace-only password-file as effectively empty
  and falls back to an interactive password prompt, regardless of
  `--insecure`.

This is macOS-only either way - `install-windows.ps1` uses a random
password for an unrelated, already-confirmed reason: there, `-p ""`
genuinely gets dropped as an argument by a PowerShell quirk (see the
`ERROR_INVALID_PASSWORD` entry above), not anything to do with per-use
prompting; `install-windows.bat` (plain `cmd.exe`) doesn't have that bug
either, but wasn't changed since it isn't broken.

### macOS: multiple back-to-back keychain password/Touch ID prompts, each just saying "security" wants access

Installing the root CA, the intermediate CA, and the device certificate are
three separate keychain-modifying operations, and macOS prompts for
authentication on each one individually - there's no way to bundle them into
a single prompt. The script checks first whether each CA is *already*
trusted (`security verify-cert`) and skips straight past it if so - so a
renewal run, which doesn't need to touch CA trust again, no longer
re-triggers those two prompts at all, only the one for the device
certificate itself. For whichever prompts do still happen, it prints a
short warning with a 2-second pause before each one (`macOS will now ask
for your password or Touch ID to trust the ROOT CA...` / `...INTERMEDIATE
CA...` / `...import the device certificate...`) specifically so it's clear
which of the three you're
approving and that more are coming, rather than three unlabeled system
dialogs firing in a row.

### macOS: configuration shows placeholder values (`step-ca.example.com`, `poc_devicetrust`, ...) even though you exported real ones

You ran the script with plain `sudo` instead of `sudo -E`. `sudo` resets the
environment by default, so every `export SCEP_*`/`ROOT_CA_*` variable you
set beforehand is invisible to the script once it's running as root - it
silently falls back to its own placeholder defaults instead of erroring.
Use `sudo -E ./install-macos.sh` (see the Enrollment section above).
Separately: always invoke it as `./install-macos.sh` (after `chmod +x`) or
`bash install-macos.sh`, matching its `#!/bin/bash` shebang, not
`sh install-macos.sh` - macOS's `sh` is bash running in POSIX mode, which
handles some things (color output included) differently than the script
expects.

### VM startup / Docker issues

- The step-ca VM has no external IP; if `docker` isn't installed or the
  container never started, check the startup script's own log:
  `sudo journalctl -u google-startup-scripts.service --no-pager`. A common
  cause is the Cloud NAT gateway being missing or misconfigured, since the
  VM has no other path to the internet for package/image installs.
- On a freshly created VM, package installs (`apt-get update`/`install`) can
  take several minutes before `docker ps` shows the container running - this
  isn't necessarily stuck, just slow.

### `terraform apply` fails with "Previously used CaPool/CertificateTemplate ids may not be reused"

Like individual `google_privateca_certificate` resources (see Known
Limitations below), **CA pools and certificate templates also have their
names permanently reserved by GCP once deleted** - discovered by actually
destroying and recreating this entire stack end-to-end. If you've ever run
`terraform destroy` against this project before, `ca_pool_name`,
`root_ca_pool_name`, and `certificate_template_name` (`variables.tf`) all
need new values before the next `apply` - there's no way to reuse the
originals.

### New external HTTPS load balancer returns TLS handshake errors for a few minutes after `apply`

The SCEP gateway's backend health check passing (`gcloud compute
backend-services get-health scep-gateway-backend --global`) only confirms
the *internal* GFE-to-VM hop is healthy - it says nothing about the
client-facing TLS edge, which is a separate piece of Google's global HTTPS
LB infrastructure that can take several minutes to propagate after the
forwarding rule is first created. A `tls: failed to verify certificate` or
"unexpected eof" error against a **brand-new** gateway IP is most likely
this, not a real misconfiguration - retry after a few minutes before
digging further.

## Cleanup

```bash
terraform destroy
```

Both CAs have `deletion_protection = true` - `destroy` will fail on them
until you temporarily set `deletion_protection = false` on
`modules/root_ca/main.tf` and `modules/intermediate_ca/main.tf` and apply
that change first. You'll also want `skip_grace_period = true` and
`ignore_active_certificates_on_deletion = true` alongside it, since CAS
otherwise refuses to delete a CA that has ever issued a certificate still
within its validity window (which, in this stack, is essentially always -
step-ca's own SCEP decrypter cert, the gateway's TLS certs, and every
enrolled device cert are all still "active" from CAS's point of view).
Revert those back to `true`/defaults afterward if you plan to redeploy for
real use - they're a genuine safety net, not just apply-time friction.

**Note:** This deletes all CA certificates and their associated data.
Exercise caution. This full cycle (destroy, flip protection back, rebuild
with bumped pool/template names per the Troubleshooting entry above) has
been run end-to-end successfully, including a fresh SCEP enrollment and
mTLS gateway test against the rebuilt stack.

## Support

- [Google Cloud Private CA Documentation](https://cloud.google.com/private-ca/docs/overview)
- [step-ca Documentation](https://smallstep.com/docs/step-ca/)
- [step-ca Registration Authority mode](https://smallstep.com/docs/step-ca/registration-authority-ca/)

## License

This configuration is provided as-is for educational and commercial use.
