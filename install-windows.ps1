# Device Trust Certificate Installation Script for Windows (PowerShell)
# This script automates the installation of scepclient, requests a device
# trust certificate, and installs it into the current user's certificate
# store with a non-exportable private key (see Readme.md for what
# "non-exportable" does and doesn't mean here, and the -KeyProtection
# trade-off).

param(
    [string]$ScepServerUrl = $env:SCEP_SERVER_URL,
    [string]$Provisioner = $env:SCEP_PROVISIONER,
    [string]$Challenge = $env:SCEP_CHALLENGE,
    [string]$RootCaUrl = $env:ROOT_CA_URL,
    [string]$RootCaFile = $env:ROOT_CA_FILE,
    [string]$IntermediateCaUrl = $env:INTERMEDIATE_CA_URL,
    [string]$IntermediateCaFile = $env:INTERMEDIATE_CA_FILE_SRC,
    [string]$Country = $env:CERT_COUNTRY,
    [string]$Organization = $env:CERT_ORGANIZATION,
    [string]$Ou = $env:CERT_OU,
    # Delete: remove the loose private key after import (default - matches
    #   "non-exportable" most literally, but forces a full re-enrollment
    #   (new key, new cert, new CA-signing operation) on every renewal.
    # RestrictPermissions: keep the key file for same-key renewal, but lock
    #   its ACL down to SYSTEM+Administrators. See Readme.md for the
    #   security/cost trade-off between these.
    [ValidateSet("Delete", "RestrictPermissions")]
    [string]$KeyProtection = $(if ($env:KEY_PROTECTION) { $env:KEY_PROTECTION } else { "Delete" }),
    [string]$MtlsGatewayUrl = $env:MTLS_GATEWAY_URL,
    # Per-device SCEP challenges (optional, needs the webhook in
    # webhook/README.md; leave these unset and this script behaves exactly as
    # it always has, sending the single static -Challenge to -Provisioner):
    #   -ScepPhrase        The current enrollment phrase. The challenge sent is
    #                      then computed from this PC's serial number:
    #                      base64(HMAC-SHA256(phrase, "device-trust-scep-challenge-v1`n" + SERIAL)).
    #   -RenewProvisioner  The renewal provisioner (device-trust-scep-renew with
    #                      the Terraform webhook). When set and the key from the
    #                      last run is still on disk (-KeyProtection
    #                      RestrictPermissions), the run renews with that same
    #                      key and needs no phrase.
    #   -ScepAttempts      How often a failed scepclient call is tried (default
    #                      3). scepclient occasionally fails on its own signature
    #                      before the request reaches step-ca; a retry works and
    #                      retrying a refused request is harmless.
    [string]$ScepPhrase = $env:SCEP_PHRASE,
    [string]$RenewProvisioner = $env:SCEP_RENEW_PROVISIONER,
    [int]$ScepAttempts = $(if ($env:SCEP_ATTEMPTS) { [int]$env:SCEP_ATTEMPTS } else { 3 })
)

# Check for Administrator privileges
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Error "This script requires Administrator privileges."
    Write-Error "Please right-click and select 'Run as administrator'"
    exit 1
}

# Configuration
$InstallDir = "C:\Program Files\scepclient"
$CertDir = "$InstallDir\certs"
$RootCaDestFile = "$CertDir\root-ca.crt"
$IntermediateCaDestFile = "$CertDir\intermediate-ca.crt"
$PrivateKeyFile = "$CertDir\client.key"
$CertFile = "$CertDir\client.crt"
$FullChainFile = "$CertDir\full-chain.pem"
$CertFriendlyName = "Device Trust Certificate"
# scepclient caches its CSR here as a sibling of -private-key/-certificate,
# and reuses it silently on the next run rather than rebuilding it from
# whatever key currently exists. If a prior run's private key was deleted
# (or never made it past this point) but csr.pem survived, scepclient will
# generate a brand-new client.key while still submitting the stale cached
# CSR - producing a certificate that doesn't match the new key at all
# (surfaces as certutil "NTE_BAD_KEY" / Bad Key on import). Cleared below
# whenever there's no private key for it to legitimately correspond to.
$CsrCacheFile = "$CertDir\csr.pem"

# Detect hostname for DNS name
$Hostname = [System.Net.Dns]::GetHostName()

# This script is safe to re-run for renewal. Renewal state is tracked via the
# certificate store (by FriendlyName) rather than loose files, since
# -KeyProtection Delete removes the loose files but the store entry persists.
# With -KeyProtection RestrictPermissions, scepclient also reuses the
# existing private key file if present (per its own -help text: "if there is
# no key, scepclient will create one"), making that combination a true
# same-key renewal; Delete forces a fresh key + full re-enrollment every time
# (see Readme.md for the cost/security trade-off).
$ExistingCert = Get-ChildItem -Path Cert:\CurrentUser\My | Where-Object { $_.FriendlyName -eq $CertFriendlyName } | Select-Object -First 1
$IsRenewal = $null -ne $ExistingCert
# Is the key from the last run still on disk? Only then can this run reuse it
# (-KeyProtection Delete removes it, so every run starts a new key).
$HaveKey = (Test-Path -Path $PrivateKeyFile) -and (Test-Path -Path $CertFile)

# Create directories
if (-not (Test-Path -Path $InstallDir)) {
    New-Item -Path $InstallDir -ItemType Directory -Force | Out-Null
}

if (-not (Test-Path -Path $CertDir)) {
    New-Item -Path $CertDir -ItemType Directory -Force | Out-Null
}

Write-Host "Device Trust Certificate Installation" -ForegroundColor Cyan
Write-Host "====================================" -ForegroundColor Cyan
Write-Host ""
if ($HaveKey) {
    Write-Host "Existing device certificate and key found - this run will renew it (same key)." -ForegroundColor Yellow
} elseif ($IsRenewal) {
    Write-Host "Existing device certificate found in Cert:\CurrentUser\My but no key to reuse - this run enrolls with a new key." -ForegroundColor Yellow
} else {
    Write-Host "No existing device certificate found - this is a first-time enrollment." -ForegroundColor Yellow
}
Write-Host ""
Write-Host "Configuration:"
Write-Host "- SCEP Server: $ScepServerUrl"
Write-Host "- Provisioner: $Provisioner"
if ($RenewProvisioner) { Write-Host "- Renewal provisioner: $RenewProvisioner" }
Write-Host "- Hostname: $Hostname"
Write-Host "- Key protection: $KeyProtection"
Write-Host "- Cert Directory: $CertDir"
Write-Host ""

# Download scepclient for Windows. Releases ship as a versioned zip
# (scepclient-windows-amd64-vX.Y.Z.zip) containing scepclient-windows-amd64.exe,
# so the asset must be discovered via the GitHub API rather than a fixed URL.
Write-Host "Downloading scepclient for Windows..." -ForegroundColor Yellow

try {
    $ProgressPreference = 'SilentlyContinue'
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/micromdm/scep/releases/latest" -UseBasicParsing
    $asset = $release.assets | Where-Object { $_.name -like "scepclient-windows-amd64-*.zip" } | Select-Object -First 1
    if (-not $asset) {
        throw "No scepclient-windows-amd64 asset found in the latest micromdm/scep release"
    }

    $zipPath = "$InstallDir\scepclient.zip"
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -UseBasicParsing
    Expand-Archive -Path $zipPath -DestinationPath $InstallDir -Force
    Move-Item -Path "$InstallDir\scepclient-windows-amd64.exe" -Destination "$InstallDir\scepclient.exe" -Force
    Remove-Item -Path $zipPath -Force
    Write-Host "Downloaded scepclient successfully" -ForegroundColor Green
} catch {
    Write-Error "Failed to download scepclient: $($_.Exception.Message)"
    exit 1
}

# Download step CLI (smallstep's own tool - already the toolchain this whole
# deployment is built around). Used below purely for its "certificate p12"
# packaging subcommand, to combine scepclient's PEM cert+key into a PFX for
# Windows cert store import - this PowerShell version has no native PEM
# parsing, and step avoids pulling in an unrelated third-party OpenSSL build.
Write-Host ""
Write-Host "Downloading step CLI..." -ForegroundColor Yellow

try {
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri "https://dl.smallstep.com/cli/docs-cli-install/latest/step_windows_amd64.zip" -OutFile "$InstallDir\step.zip" -UseBasicParsing
    Expand-Archive -Path "$InstallDir\step.zip" -DestinationPath $InstallDir -Force
    Move-Item -Path "$InstallDir\step_windows_amd64\bin\step.exe" -Destination "$InstallDir\step.exe" -Force
    Remove-Item -Path "$InstallDir\step.zip" -Force
    Remove-Item -Path "$InstallDir\step_windows_amd64" -Recurse -Force
    Write-Host "Downloaded step CLI successfully" -ForegroundColor Green
} catch {
    Write-Error "Failed to download step CLI: $($_.Exception.Message)"
    exit 1
}

# Install root CA certificate
Write-Host ""
Write-Host "Installing root CA certificate..." -ForegroundColor Yellow

if ($RootCaFile -and (Test-Path -Path $RootCaFile)) {
    Write-Host "Using local root CA file: $RootCaFile" -ForegroundColor Cyan
    Copy-Item -Path $RootCaFile -Destination $RootCaDestFile -Force
} elseif ($RootCaUrl) {
    Write-Host "Downloading root CA from: $RootCaUrl" -ForegroundColor Cyan
    try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $RootCaUrl -OutFile $RootCaDestFile -UseBasicParsing
    } catch {
        Write-Warning "Failed to download root CA: $($_.Exception.Message)"
    }
} else {
    Write-Warning "Neither -RootCaFile nor -RootCaUrl (or ROOT_CA_FILE / ROOT_CA_URL) was set."
}

if (Test-Path -Path $RootCaDestFile) {
    try {
        # The plain "Root" store triggers an interactive "Security Warning:
        # do you want to install this certificate?" dialog regardless of -f,
        # because that store is tied to the interactive desktop trust UI.
        # -enterprise targets the Enterprise store instead - the same
        # mechanism Group Policy itself uses to push trusted roots silently -
        # which Windows still consults for chain validation, but without the
        # interactive prompt.
        $certutilOutput = certutil -enterprise -f -addstore 'Root' $RootCaDestFile
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Root CA installed successfully" -ForegroundColor Green
        } else {
            Write-Warning "Failed to install root CA to system store: $certutilOutput"
        }
    } catch {
        Write-Warning "Failed to install root CA: $($_.Exception.Message)"
    }
} else {
    Write-Warning "Root CA certificate not found, but continuing..."
}

# A plain scriptblock assigned to ServerCertificateValidationCallback fails
# in Windows PowerShell 5.1 ("no Runspace available to run scripts in this
# thread") since .NET invokes it on the TLS handshake thread, which has no
# PowerShell runspace - a compiled delegate has no such dependency. Defined
# once here (guarded, so the later mTLS test section below doesn't redefine
# it) since both this intermediate-CA lookup and that test need to talk to
# the gateway's self-issued TLS certificate before it's trusted locally.
if (-not ("TrustAllCertsCallback" -as [type])) {
    Add-Type -TypeDefinition @"
using System.Net;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
public static class TrustAllCertsCallback {
    public static bool Validate(object sender, X509Certificate certificate, X509Chain chain, SslPolicyErrors sslPolicyErrors) {
        return true;
    }
}
"@
}
$trustAllMethod = [TrustAllCertsCallback].GetMethod("Validate")
$trustAllDelegate = [Delegate]::CreateDelegate([System.Net.Security.RemoteCertificateValidationCallback], $trustAllMethod)

# Fetch the intermediate CA certificate too - needed to bundle the full
# chain into the device cert's PFX below (so Windows doesn't have to rely on
# AIA fetching to build the chain during ClientAuth). If not explicitly
# provided, derive it automatically from the SCEP server's own GetCACert
# response - the same operation scepclient itself calls first, already
# public (no additional trust needed to fetch it), and returns the full
# chain (this deployment's step-ca returns both the SCEP decrypter cert and
# the intermediate CA cert as a "certs-only" PKCS#7/CMS bundle).
if ($IntermediateCaFile -and (Test-Path -Path $IntermediateCaFile)) {
    Write-Host "Using local intermediate CA file: $IntermediateCaFile" -ForegroundColor Cyan
    Copy-Item -Path $IntermediateCaFile -Destination $IntermediateCaDestFile -Force
} elseif ($IntermediateCaUrl) {
    Write-Host "Downloading intermediate CA from: $IntermediateCaUrl" -ForegroundColor Cyan
    try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $IntermediateCaUrl -OutFile $IntermediateCaDestFile -UseBasicParsing
    } catch {
        Write-Warning "Failed to download intermediate CA: $($_.Exception.Message)"
    }
} else {
    Write-Host "No -IntermediateCaFile/-IntermediateCaUrl set - deriving the intermediate CA automatically from the SCEP server's GetCACert response..." -ForegroundColor Cyan
    $originalCallback = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $trustAllDelegate
    try {
        $ProgressPreference = 'SilentlyContinue'
        $getCaCertUrl = "$ScepServerUrl/scep/$Provisioner`?operation=GetCACert"
        $caCertResponse = Invoke-WebRequest -Uri $getCaCertUrl -UseBasicParsing
        Add-Type -AssemblyName System.Security
        $signedCms = New-Object System.Security.Cryptography.Pkcs.SignedCms
        $signedCms.Decode($caCertResponse.Content)
        $intermediateCert = $signedCms.Certificates | Where-Object {
            $basicConstraints = $_.Extensions | Where-Object { $_.Oid.FriendlyName -eq "Basic Constraints" }
            $basicConstraints -and $basicConstraints.CertificateAuthority
        } | Select-Object -First 1
        if ($intermediateCert) {
            $pem = "-----BEGIN CERTIFICATE-----`n" + [Convert]::ToBase64String($intermediateCert.RawData, [System.Base64FormattingOptions]::InsertLineBreaks) + "`n-----END CERTIFICATE-----`n"
            Set-Content -Path $IntermediateCaDestFile -Value $pem -NoNewline
            Write-Host "Derived intermediate CA automatically from GetCACert" -ForegroundColor Green
        } else {
            Write-Warning "GetCACert response didn't contain a certificate with CA=true - could not derive the intermediate CA automatically."
        }
    } catch {
        Write-Warning "Failed to derive intermediate CA from GetCACert: $($_.Exception.Message)"
    } finally {
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $originalCallback
    }
}

# Request device trust certificate
Write-Host ""
Write-Host "====================================" -ForegroundColor Cyan
Write-Host "Requesting Device Trust Certificate" -ForegroundColor Cyan
Write-Host "====================================" -ForegroundColor Cyan
Write-Host ""

# Build scepclient command
$ScepTool = "$InstallDir\scepclient.exe"
$DnsName = $Hostname
$CommonName = $Hostname

# This PC's serial number, as the server's allowlist records it: trimmed and
# upper-cased. DEVICE_SERIAL overrides the hardware lookup (virtual machines
# and test rigs that report a placeholder serial).
function Get-DeviceSerial {
    if ($env:DEVICE_SERIAL) { return $env:DEVICE_SERIAL }
    (Get-CimInstance Win32_BIOS).SerialNumber
}
function Get-PhraseChallenge {
    $serial = (Get-DeviceSerial).Trim().ToUpperInvariant()
    if (-not $serial) { throw "Could not read this PC's serial number to build the per-device challenge" }
    $h = New-Object System.Security.Cryptography.HMACSHA256
    try {
        $h.Key = [Text.Encoding]::UTF8.GetBytes($ScepPhrase)
        $msg = [Text.Encoding]::UTF8.GetBytes("device-trust-scep-challenge-v1`n$serial")
        [Convert]::ToBase64String($h.ComputeHash($msg))
    } finally { $h.Dispose() }
}

# One scepclient request, retried up to -ScepAttempts times (see the parameter
# comment). Returns $true on success. Out-Host keeps scepclient's output out of
# the return value.
# usage: Invoke-ScepRequest <key-file> <cert-file> <provisioner> <challenge>
function Invoke-ScepRequest([string]$KeyFile, [string]$CertOut, [string]$ForProvisioner, [string]$ForChallenge) {
    for ($attempt = 1; $attempt -le $ScepAttempts; $attempt++) {
        $KeyDir = Split-Path -Parent $KeyFile
        Remove-Item -Path (Join-Path $KeyDir "csr.pem") -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -Path $KeyFile)) { Remove-Item -Path (Join-Path $KeyDir "self.pem") -Force -ErrorAction SilentlyContinue }
        & $ScepTool -private-key $KeyFile -certificate $CertOut -server-url "$ScepServerUrl/scep/$ForProvisioner" -challenge $ForChallenge -dnsname $DnsName -cn $CommonName -country $Country -organization $Organization -ou $Ou | Out-Host
        if ($LASTEXITCODE -eq 0) { return $true }
        if ($attempt -lt $ScepAttempts) {
            Write-Warning "scepclient attempt $attempt of $ScepAttempts failed - retrying in 2 seconds"
            Start-Sleep -Seconds 2
        }
    }
    return $false
}

# Renew with the key from the last run when we can (webhook mode); otherwise
# enroll. Without -ScepPhrase and -RenewProvisioner this is the original
# behaviour: one provisioner, the static challenge.
$Action = "enroll"
$ActiveProvisioner = $Provisioner
$ActiveChallenge = $Challenge
if ($RenewProvisioner -and $HaveKey) {
    $Action = "renew"
    $ActiveProvisioner = $RenewProvisioner
    $ActiveChallenge = "not-used-for-renewal"      # the renewal path ignores it
} elseif ($ScepPhrase) {
    $ActiveChallenge = Get-PhraseChallenge
}

Write-Host "Action: $Action via provisioner $ActiveProvisioner (the challenge itself is not printed)" -ForegroundColor Cyan
Write-Host "Command:" -ForegroundColor Cyan
Write-Host "$ScepTool -private-key `"$PrivateKeyFile`" -certificate `"$CertFile`" -server-url `"$ScepServerUrl/scep/$ActiveProvisioner`" -challenge <redacted> -dnsname `"$DnsName`" -cn `"$CommonName`" -country `"$Country`" -organization `"$Organization`" -ou `"$Ou`"" -NoNewline
Write-Host ""

# scepclient caches its CSR - challenge included - next to the key and silently
# resends it, ignoring a new -challenge. Invoke-ScepRequest therefore clears it
# before every request.
# scepclient also keeps a self-signed signer certificate (self.pem) next to the
# key and signs every request with it; a new key signed against an old self.pem
# fails with "crypto/rsa: verification error", so it goes whenever the key does.
# Remember whether a key existed, so a failed first
# enrollment can remove the key it just made instead of leaving it behind.
$KeyBeforeRun = Test-Path -Path $PrivateKeyFile

# Execute scepclient. (No file-based backup/restore needed here anymore - the
# old certificate store entry, if any, isn't touched until the new one has
# been imported successfully further down.)
$ScepOk = Invoke-ScepRequest $PrivateKeyFile $CertFile $ActiveProvisioner $ActiveChallenge

# A refused renewal (for example an administrator cleared this PC's pin, or the
# PC was replaced) falls back to enrolling with a brand-new key, if a phrase is
# available. It runs in a scratch directory so the current key and certificate
# stay untouched until the new ones have actually been issued.
if (-not $ScepOk -and $Action -eq "renew" -and $ScepPhrase) {
    Write-Warning "Renewal was refused - enrolling with a new key and the phrase instead."
    $Action = "enroll"
    $FallbackDir = Join-Path $CertDir ("enroll-" + [Guid]::NewGuid().ToString("N"))
    New-Item -Path $FallbackDir -ItemType Directory -Force | Out-Null
    $FallbackKey = Join-Path $FallbackDir "client.key"
    $FallbackCert = Join-Path $FallbackDir "client.crt"
    $ScepOk = Invoke-ScepRequest $FallbackKey $FallbackCert $Provisioner (Get-PhraseChallenge)
    if ($ScepOk -and (Test-Path -Path $FallbackCert)) {
        Move-Item -Path $FallbackKey -Destination $PrivateKeyFile -Force
        Move-Item -Path $FallbackCert -Destination $CertFile -Force
        Remove-Item -Path $CsrCacheFile -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -Path $FallbackDir -Recurse -Force -ErrorAction SilentlyContinue
}

if (-not $ScepOk) {
    Write-Host ""
    Write-Error "Certificate request failed!"
    Write-Error "Please check your SCEP server URL, challenge, and root CA installation."
    if (-not $KeyBeforeRun) {
        # The key was made for this attempt and has no certificate: don't leave it.
        Remove-Item -Path $PrivateKeyFile, $CsrCacheFile, "$CertDir\self.pem" -Force -ErrorAction SilentlyContinue
    }
    if ($IsRenewal) {
        Write-Warning "The existing certificate in Cert:\CurrentUser\My was not touched."
    }
    exit 1
}

# Verify certificate was created
if (-not (Test-Path -Path $CertFile)) {
    Write-Error "Certificate file not created"
    if ($IsRenewal) {
        Write-Warning "The existing certificate in Cert:\CurrentUser\My was not touched."
    }
    exit 1
}

# Save full certificate chain (public data only, no private key - safe to
# leave on disk regardless of -KeyProtection)
if (Test-Path -Path $FullChainFile) {
    Remove-Item -Path $FullChainFile -Force
}
Add-Content -Path $FullChainFile -Value (Get-Content -Path $RootCaDestFile)
Add-Content -Path $FullChainFile -Value (Get-Content -Path $CertFile)

# Package the cert+key(+chain) into a PFX and import it into the current
# user's certificate store with a non-exportable private key.
Write-Host ""
Write-Host "Installing certificate into Cert:\CurrentUser\My (non-exportable)..." -ForegroundColor Yellow

$PfxFile = "$CertDir\client.pfx"
if (Test-Path -Path $PfxFile) {
    Remove-Item -Path $PfxFile -Force
}

$StepTool = "$InstallDir\step.exe"

# The PFX needs a real (non-empty) password purely to work around a
# PowerShell quirk: an empty string ("") passed as a native-command argument
# can get silently dropped rather than passed through as a zero-length
# argument, which shifts every argument after it by one position. With
# "-p ''" that meant certutil actually received "-p My ..." and tried to use
# the literal word "My" (the store name) as the PFX password, failing with
# ERROR_INVALID_PASSWORD. The password itself carries no security weight -
# the PFX is shredded immediately after import - it just has to be a real
# string so the argument survives.
$PfxPasswordFile = "$CertDir\pfx-password.txt"
$PfxPassword = [System.Guid]::NewGuid().ToString("N")
Set-Content -Path $PfxPasswordFile -Value $PfxPassword -NoNewline

$stepArgs = @("certificate", "p12", $PfxFile, $CertFile, $PrivateKeyFile, "--password-file", $PfxPasswordFile, "--force")
if (Test-Path -Path $IntermediateCaDestFile) {
    $stepArgs += @("--ca", $IntermediateCaDestFile)
}
& $StepTool @stepArgs

if ($LASTEXITCODE -ne 0 -or -not (Test-Path -Path $PfxFile)) {
    Write-Error "Failed to package the certificate into a PFX with step CLI"
    Remove-Item -Path $PfxPasswordFile -Force -ErrorAction SilentlyContinue
    if ($IsRenewal) {
        Write-Warning "The existing certificate in Cert:\CurrentUser\My was not touched."
    }
    exit 1
}

# -user targets CurrentUser\My ("user space"); NoExport marks the private key
# non-exportable; NoRoot skips re-importing the bundled intermediate as a
# trusted root (it's here only so Windows can build the chain, not to be
# trusted as a CA itself); FriendlyName= is how future runs find this cert.
$importOutput = certutil -user -importpfx -p $PfxPassword My $PfxFile "NoRoot,NoExport,FriendlyName=$CertFriendlyName"
Remove-Item -Path $PfxPasswordFile -Force -ErrorAction SilentlyContinue
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to import certificate into Cert:\CurrentUser\My: $importOutput"
    if ($IsRenewal) {
        Write-Warning "The existing certificate in Cert:\CurrentUser\My was not touched."
    }
    exit 1
}

Write-Host "Certificate installed successfully (non-exportable private key)" -ForegroundColor Green

# The transient PFX is pure derived material (cert+key bundled together) -
# shred it unconditionally now that it's imported.
Remove-Item -Path $PfxFile -Force

# Now that the new certificate is confirmed installed, remove the old store
# entry it superseded (if this was a renewal).
if ($IsRenewal -and $ExistingCert) {
    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store("My", "CurrentUser")
    $store.Open("ReadWrite")
    $stillPresent = $store.Certificates | Where-Object { $_.Thumbprint -eq $ExistingCert.Thumbprint }
    if ($stillPresent) {
        $store.Remove($stillPresent)
        Write-Host "Removed the superseded certificate." -ForegroundColor Green
    }
    $store.Close()
}

# Apply the chosen key-protection mode to the loose PEM files.
Write-Host ""
Write-Host "Applying key protection mode: $KeyProtection" -ForegroundColor Yellow
if ($KeyProtection -eq "Delete") {
    Remove-Item -Path $PrivateKeyFile -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $CertFile -Force -ErrorAction SilentlyContinue
    # Delete scepclient's cached CSR too - leaving it behind is exactly what
    # causes the stale-CSR/mismatched-key bug this script now guards
    # against on the next run (see $CsrCacheFile above), so don't rely
    # solely on that guard catching it later.
    Remove-Item -Path $CsrCacheFile -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$CertDir\self.pem" -Force -ErrorAction SilentlyContinue
    Write-Host "Deleted the loose private key and certificate files. The next renewal will generate a new key (full re-enrollment)." -ForegroundColor Green
} else {
    # RestrictPermissions: keep the key file in place (so scepclient reuses
    # it for same-key renewal) but lock its ACL to SYSTEM + Administrators,
    # removing standard users' read access.
    icacls $PrivateKeyFile /inheritance:r | Out-Null
    icacls $PrivateKeyFile /grant:r "SYSTEM:F" "*S-1-5-32-544:F" | Out-Null
    Write-Host "Restricted permissions on $PrivateKeyFile to SYSTEM and Administrators." -ForegroundColor Green
}

# Prove the installed certificate actually works for TLS ClientAuth (not just
# that it was issued) by making a real mTLS request against the test gateway,
# using the cert straight from the store - the same way a real application
# (browser, conditional-access client, etc.) would use it.
$MtlsTestResult = $null
if ($MtlsGatewayUrl) {
    Write-Host ""
    Write-Host "====================================" -ForegroundColor Cyan
    Write-Host "Testing mTLS ClientAuth Against Gateway" -ForegroundColor Cyan
    Write-Host "====================================" -ForegroundColor Cyan
    Write-Host ""

    $InstalledCert = Get-ChildItem -Path Cert:\CurrentUser\My | Where-Object { $_.FriendlyName -eq $CertFriendlyName } | Select-Object -First 1
    if (-not $InstalledCert) {
        Write-Warning "Could not find the installed certificate in Cert:\CurrentUser\My - skipping mTLS test."
        $MtlsTestResult = "SKIPPED"
    } else {
        # The gateway presents a self-issued TLS certificate from our own CA
        # for its server identity, which isn't in Windows' public-CA trust
        # store - server certificate validation is bypassed here since this
        # test is specifically verifying ClientAuth (our device cert being
        # accepted), not the gateway's server identity. Reuses the
        # TrustAllCertsCallback delegate defined earlier (intermediate CA
        # lookup section) rather than redefining it.
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        $originalCallback = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $trustAllDelegate
        try {
            $response = Invoke-WebRequest -Uri $MtlsGatewayUrl -Certificate $InstalledCert -UseBasicParsing -TimeoutSec 15
            if ($response.StatusCode -eq 200 -and $response.Content -match "mTLS authentication successful") {
                Write-Host "PASS: mTLS ClientAuth succeeded against $MtlsGatewayUrl" -ForegroundColor Green
                Write-Host $response.Content
                $MtlsTestResult = "PASS"
            } else {
                Write-Warning "FAIL: Unexpected response from $MtlsGatewayUrl (status $($response.StatusCode))"
                $MtlsTestResult = "FAIL"
            }
        } catch {
            Write-Warning "FAIL: mTLS test request to $MtlsGatewayUrl failed: $($_.Exception.Message)"
            $MtlsTestResult = "FAIL"
        } finally {
            [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $originalCallback
        }
    }
} else {
    Write-Host ""
    Write-Host "Skipping mTLS test (no -MtlsGatewayUrl / MTLS_GATEWAY_URL provided)." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "====================================" -ForegroundColor Green
Write-Host "Installation Successful!" -ForegroundColor Green
Write-Host "====================================" -ForegroundColor Green
Write-Host ""
Write-Host "Certificate installed in: Cert:\CurrentUser\My (FriendlyName: $CertFriendlyName)"
Write-Host "Full chain (public data): $FullChainFile"
if ($MtlsTestResult) {
    Write-Host "mTLS gateway test: $MtlsTestResult"
}
Write-Host ""
