@echo off
REM Device Trust Certificate Installation Script for Windows
REM This script automates the installation of scepclient, requests a device
REM trust certificate, and installs it into the current user's certificate
REM store with a non-exportable private key (see Readme.md for the
REM -KeyProtection trade-off and what "non-exportable" does/doesn't mean here).

setlocal enabledelayedexpansion

REM Set installation directory (needed before the renewal check below)
set INSTALL_DIR=C:\Program Files\scepclient
set CERT_DIR=%INSTALL_DIR%\certs
set CERT_FRIENDLY_NAME=Device Trust Certificate

REM KEY_PROTECTION: Delete (default) or RestrictPermissions - see Readme.md
if not defined KEY_PROTECTION set KEY_PROTECTION=Delete

REM Renewal state is tracked via the certificate store (by FriendlyName)
REM rather than loose files, since KeyProtection=Delete removes the loose
REM files but the store entry persists.
set IS_RENEWAL=0
for /f "delims=" %%i in ('powershell -NoProfile -Command "if (Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.FriendlyName -eq '%CERT_FRIENDLY_NAME%' }) { 'yes' } else { 'no' }"') do set RENEWAL_CHECK=%%i
if "%RENEWAL_CHECK%"=="yes" set IS_RENEWAL=1

echo ========================================
echo Device Trust Certificate Installation
echo ========================================
echo.
if "%IS_RENEWAL%"=="1" (
    echo Existing device certificate found in Cert:\CurrentUser\My - this run will renew it.
) else (
    echo No existing device certificate found - this is a first-time enrollment.
)
echo.

REM Check for Administrator privileges
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Error: This script requires Administrator privileges.
    echo Please right-click and select "Run as administrator"
    pause
    exit /b 1
)

REM Configuration
set SCEP_SERVER_URL=%SCEP_SERVER_URL%
set SCEP_PROVISIONER=%SCEP_PROVISIONER%
set SCEP_CHALLENGE=%SCEP_CHALLENGE%
set CERT_COUNTRY=%CERT_COUNTRY%
set CERT_ORGANIZATION=%CERT_ORGANIZATION%
set CERT_OU=%CERT_OU%
set MTLS_GATEWAY_URL=%MTLS_GATEWAY_URL%

REM Certificate file paths (INSTALL_DIR/CERT_DIR are set earlier, before the
REM renewal check)
set ROOT_CA_FILE=%CERT_DIR%\root-ca.crt
set INTERMEDIATE_CA_FILE=%CERT_DIR%\intermediate-ca.crt
set PRIVATE_KEY_FILE=%CERT_DIR%\client.key
set CERT_FILE=%CERT_DIR%\client.crt
set FULL_CHAIN_FILE=%CERT_DIR%\full-chain.pem
set PFX_FILE=%CERT_DIR%\client.pfx
REM scepclient caches its CSR here (sibling of PRIVATE_KEY_FILE/CERT_FILE)
REM and silently reuses it on the next run regardless of whether the key
REM file it was built from still exists. If a stale csr.pem outlives its
REM key (e.g. a prior run that didn't reach the KeyProtection cleanup
REM below), scepclient generates a new key but submits the old cached CSR -
REM producing a cert that doesn't match the new key (certutil "NTE_BAD_KEY"
REM on import). Cleared below whenever there's no key for it to match.
set CSR_CACHE_FILE=%CERT_DIR%\csr.pem

REM Detect hostname for DNS name
for /f "tokens=*" %%i in ('hostname') do set HOSTNAME=%%i

REM Create installation directory
if not exist "%INSTALL_DIR%" (
    mkdir "%INSTALL_DIR%"
)

REM Create certificate directory
if not exist "%CERT_DIR%" (
    mkdir "%CERT_DIR%"
)

echo Configuration:
echo - SCEP Server: %SCEP_SERVER_URL%
echo - Provisioner: %SCEP_PROVISIONER%
echo - Hostname: %HOSTNAME%
echo - Key protection: %KEY_PROTECTION%
echo - Cert Directory: %CERT_DIR%
echo.

REM Download scepclient for Windows. Releases ship as a versioned zip
REM (scepclient-windows-amd64-vX.Y.Z.zip) containing scepclient-windows-amd64.exe,
REM so the asset must be discovered via the GitHub API rather than a fixed URL.
echo Downloading scepclient for Windows...

powershell -Command "$ProgressPreference = 'SilentlyContinue'; try { $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/micromdm/scep/releases/latest' -UseBasicParsing; $asset = $release.assets | Where-Object { $_.name -like 'scepclient-windows-amd64-*.zip' } | Select-Object -First 1; if (-not $asset) { throw 'No scepclient-windows-amd64 asset found' }; Invoke-WebRequest -Uri $asset.browser_download_url -OutFile '%INSTALL_DIR%\scepclient.zip' -UseBasicParsing; Expand-Archive -Path '%INSTALL_DIR%\scepclient.zip' -DestinationPath '%INSTALL_DIR%' -Force; Move-Item -Path '%INSTALL_DIR%\scepclient-windows-amd64.exe' -Destination '%INSTALL_DIR%\scepclient.exe' -Force; Remove-Item -Path '%INSTALL_DIR%\scepclient.zip' -Force; Write-Host 'Downloaded successfully' } catch { Write-Host ('Download failed: ' + $_.Exception.Message); exit 1 }"

if %errorLevel% neq 0 (
    echo Error: Failed to download scepclient
    pause
    exit /b 1
)

if not exist "%INSTALL_DIR%\scepclient.exe" (
    echo Error: scepclient.exe not found after download
    pause
    exit /b 1
)

REM Download step CLI (smallstep's own tool - already the toolchain this
REM whole deployment is built around). Used below purely for its
REM "certificate p12" packaging subcommand, to combine scepclient's PEM
REM cert+key into a PFX for Windows cert store import.
echo.
echo Downloading step CLI...

powershell -Command "$ProgressPreference = 'SilentlyContinue'; try { Invoke-WebRequest -Uri 'https://dl.smallstep.com/cli/docs-cli-install/latest/step_windows_amd64.zip' -OutFile '%INSTALL_DIR%\step.zip' -UseBasicParsing; Expand-Archive -Path '%INSTALL_DIR%\step.zip' -DestinationPath '%INSTALL_DIR%' -Force; Move-Item -Path '%INSTALL_DIR%\step_windows_amd64\bin\step.exe' -Destination '%INSTALL_DIR%\step.exe' -Force; Remove-Item -Path '%INSTALL_DIR%\step.zip' -Force; Remove-Item -Path '%INSTALL_DIR%\step_windows_amd64' -Recurse -Force; Write-Host 'Downloaded successfully' } catch { Write-Host ('Download failed: ' + $_.Exception.Message); exit 1 }"

if %errorLevel% neq 0 (
    echo Error: Failed to download step CLI
    pause
    exit /b 1
)

REM Install root CA certificate
echo.
echo Installing root CA certificate...
set ROOT_CA_URL=%ROOT_CA_URL%

if defined ROOT_CA_URL (
    echo Downloading root CA from: %ROOT_CA_URL%
    powershell -Command "& { $ProgressPreference = 'SilentlyContinue'; Invoke-WebRequest -Uri '%ROOT_CA_URL%' -OutFile '%ROOT_CA_FILE%' -UseBasicParsing }"
) else if defined ROOT_CA_FILE_SRC (
    echo Using local root CA file: %ROOT_CA_FILE_SRC%
    copy /y "%ROOT_CA_FILE_SRC%" "%ROOT_CA_FILE%" >nul
) else (
    echo Note: neither ROOT_CA_URL nor ROOT_CA_FILE_SRC is set.
    echo The root CA certificate must be manually installed.
)

if exist "%ROOT_CA_FILE%" (
    echo Installing root CA to Trusted Root Certification Authorities store...
    REM The plain "Root" store triggers an interactive "Security Warning" dialog
    REM regardless of -f, since that store is tied to the interactive desktop
    REM trust UI. -enterprise targets the Enterprise store instead - the same
    REM mechanism Group Policy itself uses to push trusted roots silently -
    REM which Windows still consults for chain validation, but without the prompt.
    certutil -enterprise -f -addstore "Root" "%ROOT_CA_FILE%"
    if %errorLevel% equ 0 (
        echo Root CA installed successfully
    ) else (
        echo Warning: Failed to install root CA, but continuing...
    )
) else (
    echo Warning: Root CA certificate not found, but continuing...
)

REM Fetch the intermediate CA certificate too - needed to bundle the full
REM chain into the device cert's PFX below.
if defined INTERMEDIATE_CA_URL (
    echo Downloading intermediate CA from: %INTERMEDIATE_CA_URL%
    powershell -Command "& { $ProgressPreference = 'SilentlyContinue'; Invoke-WebRequest -Uri '%INTERMEDIATE_CA_URL%' -OutFile '%INTERMEDIATE_CA_FILE%' -UseBasicParsing }"
) else if defined INTERMEDIATE_CA_FILE_SRC (
    echo Using local intermediate CA file: %INTERMEDIATE_CA_FILE_SRC%
    copy /y "%INTERMEDIATE_CA_FILE_SRC%" "%INTERMEDIATE_CA_FILE%" >nul
) else (
    echo Note: neither INTERMEDIATE_CA_URL nor INTERMEDIATE_CA_FILE_SRC is set.
)

REM Request device trust certificate
echo.
echo ========================================
echo Requesting Device Trust Certificate
echo ========================================
echo.

REM Build scepclient command
set SCEPTOOL=%INSTALL_DIR%\scepclient.exe
set STEPTOOL=%INSTALL_DIR%\step.exe
set SERVER_URL=%SCEP_SERVER_URL%/scep/%SCEP_PROVISIONER%
set DNS_NAME=%HOSTNAME%
set COMMON_NAME=%HOSTNAME%

echo Command:
echo "%SCEPTOOL%" -private-key "%PRIVATE_KEY_FILE%" -certificate "%CERT_FILE%" -server-url "%SERVER_URL%" -challenge "%SCEP_CHALLENGE%" -dnsname "%DNS_NAME%" -cn "%COMMON_NAME%" -country "%CERT_COUNTRY%" -organization "%CERT_ORGANIZATION%" -ou "%CERT_OU%"

REM If there's no private key for scepclient to reuse, it's about to
REM generate a brand-new one - clear any cached csr.pem left over from a
REM prior run so scepclient can't silently resubmit a CSR that no longer
REM matches the new key (see CSR_CACHE_FILE above).
if not exist "%PRIVATE_KEY_FILE%" if exist "%CSR_CACHE_FILE%" del "%CSR_CACHE_FILE%"

REM No file-based backup/restore needed here - the old certificate store
REM entry, if any, isn't touched until the new one has been imported
REM successfully further down.
"%SCEPTOOL%" -private-key "%PRIVATE_KEY_FILE%" -certificate "%CERT_FILE%" -server-url "%SERVER_URL%" -challenge "%SCEP_CHALLENGE%" -dnsname "%DNS_NAME%" -cn "%COMMON_NAME%" -country "%CERT_COUNTRY%" -organization "%CERT_ORGANIZATION%" -ou "%CERT_OU%"

if %errorLevel% neq 0 (
    echo.
    echo Error: Certificate request failed!
    echo Please check your SCEP server URL, challenge, and root CA installation.
    if "%IS_RENEWAL%"=="1" echo The existing certificate in Cert:\CurrentUser\My was not touched.
    pause
    exit /b 1
)

REM Verify certificate was created
if not exist "%CERT_FILE%" (
    echo Error: Certificate file not created
    if "%IS_RENEWAL%"=="1" echo The existing certificate in Cert:\CurrentUser\My was not touched.
    pause
    exit /b 1
)

REM Save full certificate chain (public data only, no private key - safe to
REM leave on disk regardless of KEY_PROTECTION)
if exist "%FULL_CHAIN_FILE%" (
    del "%FULL_CHAIN_FILE%"
)
type "%ROOT_CA_FILE%" >> "%FULL_CHAIN_FILE%"
type "%CERT_FILE%" >> "%FULL_CHAIN_FILE%"

REM Package the cert+key(+chain) into a PFX and import it into the current
REM user's certificate store with a non-exportable private key.
echo.
echo Installing certificate into Cert:\CurrentUser\My ^(non-exportable^)...

if exist "%PFX_FILE%" del "%PFX_FILE%"

set STEP_CA_ARG=
if exist "%INTERMEDIATE_CA_FILE%" set STEP_CA_ARG=--ca "%INTERMEDIATE_CA_FILE%"

"%STEPTOOL%" certificate p12 "%PFX_FILE%" "%CERT_FILE%" "%PRIVATE_KEY_FILE%" %STEP_CA_ARG% --no-password --insecure --force

if %errorLevel% neq 0 (
    echo Error: Failed to package the certificate into a PFX with step CLI
    if "%IS_RENEWAL%"=="1" echo The existing certificate in Cert:\CurrentUser\My was not touched.
    pause
    exit /b 1
)
if not exist "%PFX_FILE%" (
    echo Error: PFX file was not created
    if "%IS_RENEWAL%"=="1" echo The existing certificate in Cert:\CurrentUser\My was not touched.
    pause
    exit /b 1
)

REM -user targets CurrentUser\My ("user space"); NoExport marks the private
REM key non-exportable; NoRoot skips re-importing the bundled intermediate as
REM a trusted root; FriendlyName= is how future runs find this cert. -p ""
REM supplies the (empty) PFX password explicitly, avoiding an interactive
REM "Enter PFX password:" prompt that would otherwise appear.
certutil -user -importpfx -p "" My "%PFX_FILE%" "NoRoot,NoExport,FriendlyName=%CERT_FRIENDLY_NAME%"

if %errorLevel% neq 0 (
    echo Error: Failed to import certificate into Cert:\CurrentUser\My
    if "%IS_RENEWAL%"=="1" echo The existing certificate in Cert:\CurrentUser\My was not touched.
    pause
    exit /b 1
)

echo Certificate installed successfully ^(non-exportable private key^)

REM The transient PFX is pure derived material - shred it unconditionally
REM now that it's imported.
del "%PFX_FILE%"

REM Now that the new certificate is confirmed installed, remove any older
REM superseded entries with the same FriendlyName so only the current one
REM remains (a renewal would otherwise leave two entries side by side).
if "%IS_RENEWAL%"=="1" (
    powershell -Command "$new = Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.FriendlyName -eq '%CERT_FRIENDLY_NAME%' } | Sort-Object NotBefore -Descending | Select-Object -First 1; $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('My','CurrentUser'); $store.Open('ReadWrite'); $store.Certificates | Where-Object { $_.FriendlyName -eq '%CERT_FRIENDLY_NAME%' -and $_.Thumbprint -ne $new.Thumbprint } | ForEach-Object { $store.Remove($_) }; $store.Close(); Write-Host 'Removed superseded certificate(s).'"
)

REM Apply the chosen key-protection mode to the loose PEM files.
echo.
echo Applying key protection mode: %KEY_PROTECTION%
if /i "%KEY_PROTECTION%"=="Delete" (
    del "%PRIVATE_KEY_FILE%" 2>nul
    del "%CERT_FILE%" 2>nul
    del "%CSR_CACHE_FILE%" 2>nul
    echo Deleted the loose private key and certificate files. The next renewal will generate a new key ^(full re-enrollment^).
) else (
    REM RestrictPermissions: keep the key file in place ^(so scepclient
    REM reuses it next time - true same-key renewal^) but lock its ACL to
    REM SYSTEM + Administrators, removing standard users' read access.
    icacls "%PRIVATE_KEY_FILE%" /inheritance:r
    icacls "%PRIVATE_KEY_FILE%" /grant:r "SYSTEM:F" "*S-1-5-32-544:F"
    echo Restricted permissions on %PRIVATE_KEY_FILE% to SYSTEM and Administrators.
)

REM Prove the installed certificate actually works for TLS ClientAuth (not
REM just that it was issued) by making a real mTLS request against the test
REM gateway, using the cert straight from the store.
if defined MTLS_GATEWAY_URL (
    echo.
    echo ========================================
    echo Testing mTLS ClientAuth Against Gateway
    echo ========================================
    echo.
    REM A plain scriptblock assigned to ServerCertificateValidationCallback
    REM fails in Windows PowerShell 5.1 ("no Runspace available") since .NET
    REM invokes it on the TLS handshake thread - a compiled Add-Type delegate
    REM has no such dependency.
    powershell -Command "$ErrorActionPreference = 'Stop'; try { $cert = Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.FriendlyName -eq '%CERT_FRIENDLY_NAME%' } | Select-Object -First 1; if (-not $cert) { Write-Host 'SKIPPED: certificate not found in store'; exit 0 }; Add-Type -TypeDefinition 'using System.Net; using System.Net.Security; using System.Security.Cryptography.X509Certificates; public static class TrustAllCertsCallback { public static bool Validate(object sender, X509Certificate certificate, X509Chain chain, SslPolicyErrors sslPolicyErrors) { return true; } }'; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12; $trustAllMethod = [TrustAllCertsCallback].GetMethod('Validate'); [System.Net.ServicePointManager]::ServerCertificateValidationCallback = [Delegate]::CreateDelegate([System.Net.Security.RemoteCertificateValidationCallback], $trustAllMethod); $response = Invoke-WebRequest -Uri '%MTLS_GATEWAY_URL%' -Certificate $cert -UseBasicParsing -TimeoutSec 15; if ($response.StatusCode -eq 200 -and $response.Content -match 'mTLS authentication successful') { Write-Host ('PASS: mTLS ClientAuth succeeded against %MTLS_GATEWAY_URL%'); Write-Host $response.Content } else { Write-Host ('FAIL: unexpected response status ' + $response.StatusCode); exit 1 } } catch { Write-Host ('FAIL: ' + $_.Exception.Message); exit 1 }"
) else (
    echo.
    echo Skipping mTLS test ^(MTLS_GATEWAY_URL not set^).
)

echo.
echo ========================================
echo Installation Successful!
echo ========================================
echo.
echo Certificate installed in: Cert:\CurrentUser\My ^(FriendlyName: %CERT_FRIENDLY_NAME%^)
echo Full chain ^(public data^): %FULL_CHAIN_FILE%
echo.

pause
