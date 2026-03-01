# Device Trust Certificate Installation Script for Windows (PowerShell)
# This script automates the installation of scepclient and requests a device trust certificate

param(
    [string]$ScepServerUrl = $env:SCEP_SERVER_URL,
    [string]$Provisioner = $env:SCEP_PROVISIONER,
    [string]$Challenge = $env:SCEP_CHALLENGE,
    [string]$RootCaUrl = $env:ROOT_CA_URL,
    [string]$Country = $env:CERT_COUNTRY,
    [string]$Organization = $env:CERT_ORGANIZATION,
    [string]$Ou = $env:CERT_OU
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
$RootCaFile = "$CertDir\root-ca.crt"
$PrivateKeyFile = "$CertDir\client.key"
$CertFile = "$CertDir\client.crt"
$FullChainFile = "$CertDir\full-chain.pem"

# Detect hostname for DNS name
$Hostname = [System.Net.Dns]::GetHostName()

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
Write-Host "Configuration:"
Write-Host "- SCEP Server: $ScepServerUrl"
Write-Host "- Provisioner: $Provisioner"
Write-Host "- Hostname: $Hostname"
Write-Host "- Cert Directory: $CertDir"
Write-Host ""

# Download scepclient for Windows
Write-Host "Downloading scepclient for Windows..." -ForegroundColor Yellow
$ScepClientUrl = "https://github.com/micromdm/scep/releases/latest/download/scepclient-windows-amd64.exe"

try {
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $ScepClientUrl -OutFile "$InstallDir\scepclient.exe" -UseBasicParsing
    Write-Host "✓ scepclient downloaded successfully" -ForegroundColor Green
} catch {
    Write-Error "Failed to download scepclient: $($_.Exception.Message)"
    exit 1
}

# Install root CA certificate
Write-Host ""
Write-Host "Installing root CA certificate..." -ForegroundColor Yellow

if ($RootCaUrl) {
    Write-Host "Downloading root CA from: $RootCaUrl" -ForegroundColor Cyan
    try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $RootCaUrl -OutFile $RootCaFile -UseBasicParsing
    } catch {
        Write-Warning "Failed to download root CA: $($_.Exception.Message)"
    }
}

if (Test-Path -Path $RootCaFile) {
    try {
        $certutil = certutil -addstore 'Root' $RootCaFile
        if ($LASTEXITCODE -eq 0) {
            Write-Host "✓ Root CA installed successfully" -ForegroundColor Green
        } else {
            Write-Warning "Failed to install root CA to system store: $certutil"
        }
    } catch {
        Write-Warning "Failed to install root CA: $($_.Exception.Message)"
    }
} else {
    Write-Warning "Root CA certificate not found, but continuing..."
}

# Request device trust certificate
Write-Host ""
Write-Host "====================================" -ForegroundColor Cyan
Write-Host "Requesting Device Trust Certificate" -ForegroundColor Cyan
Write-Host "====================================" -ForegroundColor Cyan
Write-Host ""

# Build scepclient command
$ScepTool = "$InstallDir\scepclient.exe"
$ServerUrl = "$ScepServerUrl/scep/$Provisioner"
$DnsName = $Hostname
$CommonName = $Hostname

Write-Host "Command:" -ForegroundColor Cyan
Write-Host "$ScepTool -private-key `"$PrivateKeyFile`" -server-url `"$ServerUrl`" -challenge `"$Challenge`" -dnsname `"$DnsName`" -cn `"$CommonName`" -country `"$Country`" -organization `"$Organization`" -ou `"$Ou`"" -NoNewline
Write-Host ""

# Execute scepclient
& $ScepTool -private-key $PrivateKeyFile -server-url $ServerUrl -challenge $Challenge -dnsname $DnsName -cn $CommonName -country $Country -organization $Organization -ou $Ou

if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Error "Error: Certificate request failed!" -ForegroundColor Red
    Write-Error "Please check your SCEP server URL, challenge, and root CA installation."
    exit 1
}

# Verify certificate was created
if (-not (Test-Path -Path $CertFile)) {
    Write-Error "Error: Certificate file not created" -ForegroundColor Red
    exit 1
}

# Save full certificate chain
if (Test-Path -Path $FullChainFile) {
    Remove-Item -Path $FullChainFile -Force
}

# Concatenate certificates
Add-Content -Path $FullChainFile -Value (Get-Content -Path $RootCaFile)
Add-Content -Path $FullChainFile -Value (Get-Content -Path $CertFile)

Write-Host ""
Write-Host "====================================" -ForegroundColor Green
Write-Host "Installation Successful!" -ForegroundColor Green
Write-Host "====================================" -ForegroundColor Green
Write-Host ""
Write-Host "Files created:"
Write-Host "- Private Key: $PrivateKeyFile"
Write-Host "- Certificate: $CertFile"
Write-Host "- Full Chain: $FullChainFile"
Write-Host ""
Write-Host "You can now import these certificates into your applications."
Write-Host ""