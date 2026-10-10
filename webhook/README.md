# device-trust-webhook

A small step-ca webhook that gives **every device its own SCEP challenge for enrollment** and lets enrolled devices **renew without any shared secret**, instead of one long-lived challenge shared by the whole fleet.

It applies to the **GCP deployment** in this repository (step-ca in front of Google Cloud Private CA). The beta AWS support does not use step-ca.

## Why

With a static SCEP challenge in the MDM install script, anyone who can read the script on one endpoint (a compromised machine, or a curious user) can enroll any device they like, forever. Here the secret is a **short-lived phrase** that only matters at enrollment, and every challenge is bound to **one device's serial number**.

- Only hosts on the **allowlist** can enroll. A personal laptop that isn't listed is refused even if its owner has the phrase.
- The challenge has to be computed from the serial number the allowlist records for the claimed hostname, so claiming someone else's hostname doesn't work unless you also know their serial.
- A phrase **expires**, or can be **revoked**, and each host can use each phrase **once**.
- **Renewals need no secret at all**: the webhook only accepts a renewal signed with the key the host enrolled with.

## How it works

Two SCEP provisioners on the same CA, each with this webhook attached. The webhook tells them apart by the (signed) provisioner name in each request.

| | **Enrollment** (`device-trust-scep`) | **Renewal** (`device-trust-scep-renew`) |
| --- | --- | --- |
| For | a device's first certificate, or a replacement device / new key | refreshing the certificate of an enrolled device |
| Proof | challenge computed from the device's **serial number** and a **short-lived phrase** | the CSR carries **the same public key the host enrolled with** |
| Phrase needed | yes | **no** |
| Single use | yes: each host can use each phrase once | n/a |
| Allowlist | host must be listed | host must be listed |
| Effect | records the CSR's public key as the host's *pin* | none |

Why renewal needs no secret: a certificate issued for the pinned public key is useless to anyone who doesn't hold the matching private key. The worst a stranger could get from the renewal endpoint is a fresh certificate for a device's own key. The pin also ties the request to the claimed hostname, so a device can't renew as another host.

### Enrollment

The MDM runs the **same script on every endpoint**, passing in only the current enrollment phrase. Each endpoint:

1. reads its own **serial number** from the hardware,
2. computes `challenge = base64( HMAC-SHA256( key = phrase, message = "device-trust-scep-challenge-v1\n" + SERIAL ) )`,
3. sends a SCEP request to the **enrollment provisioner** whose CSR has **`CN = its hostname`** (and, if it adds a DNS SAN, that same hostname), with the challenge as the SCEP challenge password.

The webhook:

1. takes the hostname from the CSR's CN (or its first DNS name if the CN is empty),
2. looks it up in the allowlist to get the **serial number** recorded for that host,
3. computes the same HMAC for each currently valid phrase and compares,
4. checks the CSR asks for nothing but that hostname (see below),
5. if the phrase hasn't already been used by this host, records the use and **pins the CSR's public key** to the host, and allows.

Serial numbers are trimmed and upper-cased before hashing, so `c02abc123xyz` and `C02ABC123XYZ` agree. Known answer: phrase `Queen-Ate-Lamp-Wise-Smell`, serial `C02ABC123XYZ` gives `6ZR262r4trPJ6vKSEOgBATU4m8NXj97z0oOmBt/wo8c=` (computed independently with OpenSSL and PowerShell, which agree with the Go code).

HMAC rather than AES: the server knows the serial and the phrase, so it only ever needs to recompute and compare. HMAC is one-way, so a challenge that leaks doesn't reveal the phrase, and it needs no IV or padding. It is available everywhere AES is: `openssl`, .NET, Go.

### Renewal

The client sends the CSR for its **existing private key** to the **renewal provisioner**, with the same CN/SAN as before. No phrase is involved, and whatever challenge the client sends is ignored. The webhook allows it if the host is still on the allowlist and the CSR's public key equals the pin.

- It doesn't depend on the old certificate still being valid, so a laptop that was offline past its renewal window can still renew.
- A host removed from the allowlist stops renewing as soon as the file updates, and its current certificate runs out at its expiry. This is the kill switch for decommissioned devices; for faster action also revoke the certificate.
- A host with no pin (it never enrolled through this server) can't renew: it must enroll first.

### What the webhook refuses in the CSR

The certificate template in this repo (`modules/certificate_template`) copies the CSR's subject and SANs into the issued certificate. Without a check, a host that is allowed to enroll as `laptop-01` could add `laptop-02`, or an email address, to the SANs and get a certificate that names something else. So in both modes the webhook denies a request whose SAN extension contains anything other than DNS names equal to the claimed hostname or its subdomains. Subject fields other than the CN (O, OU, C and so on) are **not** checked and still pass through to the certificate; if anything downstream trusts those, restrict them in the template.

## Key handling: two modes, pick per device group

The renewal path only works if the device can still use the key it enrolled with. That is a choice about where the private key lives after the certificate is installed:

| | **Renewable key** | **Delete after import** |
| --- | --- | --- |
| Where the key lives | as a file (`C:\Program Files\scepclient\certs` locked to SYSTEM and Administrators on Windows; `~/.device-trust`, mode 600, on macOS) **and** in the keychain/cert store, imported non-exportable | only in the keychain/cert store, imported non-exportable; the loose files are deleted |
| Renewal | `scepclient` reuses the key, renewal provisioner, **no phrase** | no key to reuse, so every renewal is a **new enrollment** with that cycle's phrase and a fresh key |
| Phrase distribution | enrollment only (onboarding batches) | every renewal cycle (monthly), to the whole fleet |
| Key rotation | the key never changes unless you re-enroll | a new key every cycle |
| What an attacker with admin on the device gets | the key file, so a copy usable anywhere, and renewal rights until you remove the host or clear its pin | the keychain/store copy is non-exportable, but admin can still use it locally and can see the phrase when it is delivered |
| What a standard (non-admin) user gets | Windows: nothing, the key file is not readable and the store copy is non-exportable. **macOS: the key file**, because the scripts run as the logged-in user and the file has to be readable by them, so on a Mac this mode protects against other users, not against the user themselves | nothing |
| CAS cost per renewal | one certificate issuance | one certificate issuance |

How to choose: use **renewable** for Windows devices whose users are not local administrators; it removes the monthly fleet-wide phrase. On macOS the user can read the key file, so prefer **delete after import** there unless that exposure is acceptable. Use **delete after import** where users are local administrators, accepting that the phrase goes to those devices every cycle. Mixed fleets work: the webhook doesn't know or care which mode a host uses. A host in delete mode simply always uses the enrollment provisioner.

Non-exportability protects against a standard user, not against an administrator, in either mode. A hardware-bound key (TPM or Secure Enclave) with a client that can sign with it would close that gap; `scepclient` can't, so it is out of scope here.

### The install scripts

[`install-macos.sh`](../install-macos.sh), [`install-windows.ps1`](../install-windows.ps1) and [`install-windows.bat`](../install-windows.bat) already request the certificate, import it and test it, so they carry the webhook support as options instead of there being a second set of scripts. Leave the options unset and they behave as before: one provisioner, the static `SCEP_CHALLENGE`.

| Option (environment variable) | PowerShell parameter | What it does |
| --- | --- | --- |
| `SCEP_PHRASE` | `-ScepPhrase` | the current enrollment phrase; the challenge sent is computed from this device's serial number (`ioreg` on macOS, `Win32_BIOS` on Windows; `DEVICE_SERIAL` overrides it for virtual machines and test rigs) |
| `SCEP_RENEW_PROVISIONER` | `-RenewProvisioner` | the renewal provisioner (`device-trust-scep-renew`). When it is set and the key from the last run is still on disk, the run renews with that key and needs no phrase |
| `KEY_PROTECTION` | `-KeyProtection` | `Delete` (the default, on all three scripts): import, then remove the key files, so every run is a new enrollment. `RestrictPermissions`: keep the key, locked down, for same-key renewal |
| `SCEP_ATTEMPTS` | `-ScepAttempts` | how often a failed `scepclient` call is tried (default 3) |

They also:

- **retry** a failed `scepclient` call, because `scepclient` occasionally fails on its own signature before the request reaches the webhook (see "Gotchas"). Retrying a request the webhook really refused is harmless; only an allowed request uses up a phrase.
- **fall back to enrolling** when a renewal is refused and a phrase is set (for example an administrator cleared the host's pin), in a scratch directory so the current key and certificate stay in place until the new ones are issued; without a phrase they stop and say why.
- **leave nothing behind on a failed first enrollment**: the key made for that attempt is removed, so a Delete-mode device doesn't keep a key it never got a certificate for.
- **never print the challenge** (the command line they echo shows `<redacted>`).

```bash
# macOS, renewable key: the first run enrolls, later runs renew with no phrase
export SCEP_SERVER_URL=https://203.0.113.10 MTLS_GATEWAY_URL=https://203.0.113.20/
export SCEP_RENEW_PROVISIONER=device-trust-scep-renew KEY_PROTECTION=RestrictPermissions
SCEP_PHRASE='Queen-Ate-Lamp-Wise-Smell' sudo -E ./install-macos.sh
sudo -E ./install-macos.sh

# macOS, delete after import (the default): every run enrolls with the cycle's phrase
SCEP_PHRASE='...' sudo -E ./install-macos.sh
```

```powershell
# Windows (elevated, or SYSTEM from the MDM)
$env:SCEP_SERVER_URL = "https://203.0.113.10"
$env:SCEP_RENEW_PROVISIONER = "device-trust-scep-renew"
$env:SCEP_PHRASE = "Queen-Ate-Lamp-Wise-Smell"
.\install-windows.ps1 -KeyProtection RestrictPermissions    # first run enrolls, later runs renew with no phrase
.\install-windows.ps1 -KeyProtection Delete                 # every run enrolls, imports (NoExport), then deletes the key
```

`install-windows.bat` takes the same settings as environment variables (`set SCEP_PHRASE=...`).

`scepclient` keeps two files next to the key. `csr.pem` is its cached CSR, challenge included, and it resends that file on the next run even when you pass a new `-challenge`, so a leftover `csr.pem` silently replays an old phrase. `self.pem` is the self-signed certificate it signs requests with; a new key signed against an old `self.pem` fails with `crypto/rsa: verification error`. The install scripts clear `csr.pem` before every request and `self.pem` whenever a new key is about to be made. If you write your own wrapper, do the same.

## Deploying with Terraform

The webhook is optional and off by default; with it off, the Terraform behaves exactly as before (one static challenge).

```bash
# 1. Build the Linux binary Terraform uploads
cd webhook && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o device-trust-webhook . && cd ..
```

```hcl
# terraform.tfvars
enable_webhook      = true
webhook_binary_path = "webhook/device-trust-webhook"
scep_cert_lifetime  = "1080h"          # 45 days; step-ca's default is 24 hours

webhook_devices = <<-EOT
  # hostname,serial,note
  ALICE-MBP,C02ABC123XYZ,Alice's MacBook
  WIN-0042,5CG1234ABC
EOT
```

`terraform apply` then:

- turns the existing `device-trust-scep` provisioner into the **enrollment** provisioner and adds `device-trust-scep-renew`, both calling the webhook (the static challenge is no longer used),
- issues the webhook a TLS certificate from your intermediate CA (step-ca trusts it for webhooks) and runs the webhook on the step-ca VM as a systemd service on the Docker bridge address `172.17.0.1:8081`, reachable only from the VM,
- stores the allowlist and TLS material in Secret Manager; the VM re-reads them every 5 minutes,
- keeps the database (phrases and pinned keys) on its own 1 GB persistent disk.

### Operating it

All admin commands run on the step-ca VM as `sudo dtw ...` (a wrapper that points at the database). The VM has no external IP, so reach it through IAP:

```bash
gcloud compute ssh step-ca --zone us-central1-a --tunnel-through-iap
```

| Task | Command |
| --- | --- |
| New enrollment phrase for an onboarding batch | `sudo dtw phrase new -wordlist /path/to/wordlist.txt -expires-in 72h` (prints only the phrase) |
| Phrase you made yourself | `echo "$PHRASE" \| sudo dtw phrase add -phrase-file - -expires-in 72h` |
| See phrases and how many hosts used each | `sudo dtw phrase list` |
| Stop a phrase now | `sudo dtw phrase revoke <id>` |
| Who enrolled with which phrase, when | `sudo dtw uses list` |
| Which key each host enrolled with | `sudo dtw pins list` |
| Let a host enroll again with a used phrase (issuance failed) | `sudo dtw uses reset <hostname>` |
| Make a host enroll again before it can renew | `sudo dtw pins clear <hostname>` |
| Add or remove devices | add a new version of the `step-ca-dtw-devices` secret: `gcloud secrets versions add step-ca-dtw-devices --data-file=devices.csv`; the VM picks it up within 5 minutes (`sudo /usr/local/bin/dtw-refresh` to apply it now) |

`phrase new` draws 5 random words from a word list you supply, one word per line (EFF and diceware files work unchanged, dice numbers included). The allowlist is one device per line, `HOSTNAME,SERIAL[,note]`; hostnames and serials are case-insensitive and each must be unique. If a sync job from an inventory system writes the allowlist, make it refuse to replace it with an empty list or one far smaller than the current one.

Decommissioning a device is removing its line: it stops renewing within minutes, and its certificate runs out at expiry (revoke it as well for immediate effect). Replacing a device or giving it a new key is another enrollment with a fresh phrase, which replaces the pin.

**The pins are the only record of which key each host enrolled with.** They live on the persistent disk; back it up. If the database is lost, every host must enroll again.

## Running the server yourself

```bash
export DTW_SIGNING_SECRETS=...       # the webhook signing secret(s) step-ca gave you (base64); comma or space separated
device-trust-webhook serve -devices devices.csv -db webhook.db \
    -enroll-provisioner device-trust-scep -renew-provisioner device-trust-scep-renew \
    -tls-cert tls.crt -tls-key tls.key -listen 127.0.0.1:8081
```

| Flag | Meaning |
| --- | --- |
| `-devices` | allowlist file (env `DTW_DEVICES`); re-read when it changes |
| `-enroll-provisioner`, `-renew-provisioner` | SCEP provisioner names to serve (at least one); requests from any other name are refused |
| `-tls-cert`, `-tls-key` | **required**: step-ca only calls `https` webhook URLs. Re-read when the files change, so renewing the certificate needs no restart |
| `-insecure-http` | plain HTTP, for local testing only |
| `-no-signing-secret` | accept step-ca's empty-key signature (see below) |
| `-signing-secrets-file`, `DTW_SIGNING_SECRETS` | signing secret(s); step-ca makes one per webhook |
| `-db` | SQLite database (env `DTW_DB`); phrases are stored in plaintext because they must be recomputable, so keep it on a private volume (created mode 0600) |

Logs never contain phrases, challenges, keys or serial numbers.

### How the webhook authenticates step-ca

A step-ca configured through a static `ca.json` (as this repo does, in cloud-CAS registration-authority mode) can attach webhooks with `options.webhooks`, and this works without step-ca's remote management. But step-ca doesn't read the webhook's signing secret from the file, so it signs requests with an **empty key**. The signature then only detects corruption; it doesn't prove who sent the request. That is why the Terraform runs the webhook with `-no-signing-secret` on an address only the VM can reach (the Docker bridge, no firewall rule opens it), and why you should do the same if you run it elsewhere. If you manage webhooks through step-ca's admin API instead, you get a real signing secret: pass it in `DTW_SIGNING_SECRETS` and leave `-no-signing-secret` off.

## Verified, and not

The Terraform was applied, torn down, and applied again from scratch several times (82 resources each time, destroyed cleanly with nothing left billing). The Go code has 93 test cases (`go test ./...`) covering the challenge formula, allowlist, store, server (including the SAN rules) and CLI.

The last cycle tested the install scripts themselves against that rebuilt stack, 31 certificates in all:

- **`install-windows.ps1` and `install-windows.bat` on a real Windows Server 2022 VM** (running as SYSTEM): enroll with `RestrictPermissions`, renew with no phrase (same key, new serial, one certificate left in the store), one-time enroll with `Delete` (no key, certificate, CSR or signer file left on disk), a Delete-mode device refused when it tries to renew without a phrase, a pin cleared by an administrator followed by the script's fallback to a fresh enrollment, and a phrase that had already been used refused when a new key presented it. 55 of 57 checks passed first time; the two that did not were a wrong assumption in my test (see the next list), and the corrected test passed. After every successful run the certificate in the Windows store, which `PfxExport` refuses to export, authenticated against the mTLS gateway both through the script's own test and through an independent `HttpWebRequest`.
- **`install-macos.sh` in a Linux container** with the real `scepclient` and stand-ins for `sudo`, `security`, `ioreg` and `step`: the same scenarios (30 checks), including the serial read from `ioreg` output and ClientAuth with the identity held in the emulated keychain after the loose key files were deleted.

Checked in the earlier rebuild cycles: enrollment with a phrase then renewal with no phrase (new certificate and serial, same public key, 45 day lifetime, hostname as the only SAN, clientAuth in the extended key usage); refusals for a wrong phrase, the right phrase with the wrong serial, a host not on the allowlist, renewal with another host's key, renewal by a host that never enrolled, and certificates asking for another host's name, a lookalike domain, or a comma-injected second name; decommissioning by publishing a new allowlist secret version, with the VM's timer picking it up on its own; and a hard VM reset leaving the pins and single-use records intact. In the last cycle the decision log recorded 31 allows and 57 refusals.

What the tests taught me:

- **The same phrase with the same key is accepted again.** The SCEP transaction ID is derived from the key, so a repeat of an already-allowed request is treated as a retry. A device that still holds its pinned key can ask again and gets a new certificate for that key, which gives an attacker nothing. A *new* key with an already-used phrase is refused, which is what a stolen phrase looks like.
- **`csr.pem` and `self.pem`** (see "The install scripts") made repeated runs fail or silently replay an old phrase until the scripts cleared them (they do now).
- **A failed first enrollment left its new key behind**; the scripts now remove it.

Not run: the macOS keychain commands on a real Mac (`security import -x`, `delete-certificate`, `add-trusted-cert`, and the new key deletion after the mTLS test; the container used stand-ins for them), the macOS behaviour that old private keys stay in the keychain after a Delete-mode renewal, and a deployment with `enable_webhook = false` (the rendered configuration is checked, the old path is unchanged).

## What this does and doesn't give you

This limits exposure; it is **not device attestation**. For enrollment, the hostname in the CSR is a claim and the serial number is the only thing tying it to hardware, and serial numbers are not secret (they're on the sticker and in the inventory).

- **Holds up against:** someone with a personal or unmanaged device and a copy of the phrase (their serial isn't listed), a stale phrase, a shared permanent secret, and renewal abuse (a stranger can't renew as an enrolled host without its key).
- **Does not hold up against:** someone who has the current enrollment phrase *and* knows a listed device's hostname and serial *and* gets to the enrollment endpoint before that device does. They can enroll as it and pin their own key. Single use means whoever enrolls first in the phrase's lifetime wins, so keep phrase lifetimes short, hand a phrase only to the devices being onboarded, and watch `uses list`.
- **Trust on first use:** the pin is whatever key the first allowed enrollment presents, so the quality of that moment is the quality of the whole chain.
- **Existing certificates have no pin.** Devices that already hold certificates from before this server existed must enroll once.
- **Single use records the webhook's decision, not that a certificate was issued.** If issuance fails after the webhook said yes, `uses reset <hostname>`.
- **Operational:** a renamed host fails until the allowlist is updated; VMs and white-box PCs often report placeholder serials ("To Be Filled By O.E.M.", empty), so check what your fleet actually returns before you build the inventory. Duplicate serials are rejected at load.

## Gotchas found in testing

- **Certificates last 24 hours by default** (step-ca's default). Set `scep_cert_lifetime` (for example `1080h`) before you plan renewal windows.
- **A CRLF checkout breaks startup scripts.** On Windows with `core.autocrlf=true` the repo checks out with CRLF line endings, HCL heredocs keep the carriage returns, and the VM's startup script fails with `bad interpreter: /bin/bash^M`. The Terraform now strips them.
- **The first `apply` of a new environment could fail with `404 Requested entity was not found`** on every certificate issued from the intermediate CA, because the CA isn't usable for a few seconds after creation. A 60 second wait now sits between the CA and everything that issues from it.
- **CA pool and certificate template names can never be reused** after deletion, so each destroy-and-rebuild needs new `ca_pool_name`, `root_ca_pool_name` and `certificate_template_name`. CA names are scoped to their pool: `root-ca` and `intermediate-ca` were reused in a new pool without trouble.
- **`scepclient` fails on its own signature a few percent of the time.** It signs each request with a throwaway certificate whose validity starts at the current time, and step-ca rejects a signing time outside that window with `pkcs7: signing time ... is outside of certificate validity`, before the webhook is consulted. In 60 free test requests, 4 never reached the webhook (one with that error, three that only showed a bare `badRequest`; I did not confirm the cause of those three). It is not specific to this webhook. The install scripts retry.
- **A hard VM reset loses the last seconds of the journal**, so a request/decision cross-check run after a reboot comes up short. Check before rebooting.
- **`docker ps` shows step-ca as `(unhealthy)`** in RA mode (the image's built-in health check exits 1 and I did not chase why). The load balancer's own health check passes and the service works.
- **Tearing down a test environment** needs the deletion knobs, since the CAs are protected by default. A destroy uses the values recorded in state, so switch the protection off with an apply first, then destroy, passing the same values both times:

  ```bash
  FLAGS="-var ca_deletion_protection=false -var ca_skip_grace_period=true -var ca_ignore_active_certificates_on_deletion=true"
  terraform apply   $FLAGS     # updates the CAs in place; nothing is replaced
  terraform destroy $FLAGS
  ```

  `skip_grace_period` deletes the CAs immediately instead of keeping them for 30 days; a deleted CA is not billed either way.

## Build and test

```bash
cd webhook
go test ./...
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o device-trust-webhook .
```

`testdata/step_ca_scep_request.json` is a real request generated with step-ca's own types, and the tests run against it.
