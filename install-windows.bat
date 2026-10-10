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

REM Per-device SCEP challenges (optional, needs the webhook in
REM webhook/README.md; leave these unset and this script behaves exactly as it
REM always has, sending the single static SCEP_CHALLENGE to SCEP_PROVISIONER):
REM   SCEP_PHRASE             the current enrollment phrase; the challenge sent is
REM                           then computed from this PC's serial number
REM   SCEP_RENEW_PROVISIONER  the renewal provisioner (device-trust-scep-renew with
REM                           the Terraform webhook); used when the key from the
REM                           last run is still on disk (RestrictPermissions)
REM   SCEP_ATTEMPTS           how often a failed scepclient call is tried (default 3);
REM                           scepclient occasionally fails on its own signature
REM                           before the request reaches step-ca
if not defined SCEP_ATTEMPTS set SCEP_ATTEMPTS=3

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
REM Is the key from the last run still on disk? Only then can this run reuse it
REM (KEY_PROTECTION=Delete removes it, so every run starts a new key).
set HAVE_KEY=0
if exist "%PRIVATE_KEY_FILE%" if exist "%CERT_FILE%" set HAVE_KEY=1

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
set DNS_NAME=%HOSTNAME%
set COMMON_NAME=%HOSTNAME%

REM Renew with the key from the last run when we can (webhook mode); otherwise
REM enroll. Without SCEP_PHRASE and SCEP_RENEW_PROVISIONER this is the original
REM behaviour: one provisioner, the static challenge.
set ACTION=enroll
set ACTIVE_PROVISIONER=%SCEP_PROVISIONER%
set ACTIVE_CHALLENGE=%SCEP_CHALLENGE%
if defined SCEP_RENEW_PROVISIONER if "%HAVE_KEY%"=="1" goto :action_renew
if defined SCEP_PHRASE (
    call :compute_challenge
    if errorlevel 1 (
        echo Error: could not build the per-device challenge from this PC's serial number
        pause
        exit /b 1
    )
    set ACTIVE_CHALLENGE=!COMPUTED_CHALLENGE!
)
goto :action_ready
:action_renew
set ACTION=renew
set ACTIVE_PROVISIONER=%SCEP_RENEW_PROVISIONER%
set ACTIVE_CHALLENGE=not-used-for-renewal
:action_ready

echo Action: %ACTION% via provisioner %ACTIVE_PROVISIONER% ^(the challenge itself is not printed^)
echo Command:
echo "%SCEPTOOL%" -private-key "%PRIVATE_KEY_FILE%" -certificate "%CERT_FILE%" -server-url "%SCEP_SERVER_URL%/scep/%ACTIVE_PROVISIONER%" -challenge "<redacted>" -dnsname "%DNS_NAME%" -cn "%COMMON_NAME%" -country "%CERT_COUNTRY%" -organization "%CERT_ORGANIZATION%" -ou "%CERT_OU%"

REM scepclient caches its CSR - challenge included - next to the key and silently
REM resends it, ignoring a new -challenge. :run_scep therefore clears it before
REM every request.
REM scepclient also keeps a self-signed signer certificate (self.pem) next to the
REM key and signs every request with it; a new key signed against an old self.pem
REM fails with "crypto/rsa: verification error", so it goes whenever the key does.
REM Remember whether a key existed, so a failed first enrollment
REM can remove the key it just made instead of leaving it behind.
set KEY_BEFORE_RUN=0
if exist "%PRIVATE_KEY_FILE%" set KEY_BEFORE_RUN=1

REM No file-based backup/restore needed here - the old certificate store
REM entry, if any, isn't touched until the new one has been imported
REM successfully further down.
set SCEP_FAILED=0
call :run_scep "%PRIVATE_KEY_FILE%" "%CERT_FILE%" "%ACTIVE_PROVISIONER%" "%ACTIVE_CHALLENGE%"
if errorlevel 1 set SCEP_FAILED=1

REM A refused renewal (for example an administrator cleared this PC's pin, or
REM the PC was replaced) falls back to enrolling with a brand-new key, if a
REM phrase is available. It runs in a scratch directory so the current key and
REM certificate stay untouched until the new ones have actually been issued.
if "%SCEP_FAILED%"=="1" if "%ACTION%"=="renew" if defined SCEP_PHRASE (
    echo Renewal was refused - enrolling with a new key and the phrase instead.
    set ACTION=enroll
    set FALLBACK_DIR=%CERT_DIR%\enroll-%RANDOM%%RANDOM%
    mkdir "!FALLBACK_DIR!"
    call :compute_challenge
    call :run_scep "!FALLBACK_DIR!\client.key" "!FALLBACK_DIR!\client.crt" "%SCEP_PROVISIONER%" "!COMPUTED_CHALLENGE!"
    if not errorlevel 1 if exist "!FALLBACK_DIR!\client.crt" (
        move /y "!FALLBACK_DIR!\client.key" "%PRIVATE_KEY_FILE%" >nul
        move /y "!FALLBACK_DIR!\client.crt" "%CERT_FILE%" >nul
        del "%CSR_CACHE_FILE%" 2>nul
        set SCEP_FAILED=0
    )
    rmdir /s /q "!FALLBACK_DIR!"
)

if "%SCEP_FAILED%"=="1" (
    echo.
    echo Error: Certificate request failed!
    echo Please check your SCEP server URL, challenge, and root CA installation.
    REM The key was made for this attempt and has no certificate: don't leave it.
    if "%KEY_BEFORE_RUN%"=="0" del "%PRIVATE_KEY_FILE%" "%CSR_CACHE_FILE%" "%CERT_DIR%\self.pem" 2>nul
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
    del "%CERT_DIR%\self.pem" 2>nul
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
goto :eof

REM ---------------------------------------------------------------------------
REM :compute_challenge - builds the per-device challenge from SCEP_PHRASE and this
REM PC's serial number (DEVICE_SERIAL overrides the BIOS lookup for virtual
REM machines and test rigs) into COMPUTED_CHALLENGE. The PowerShell has no inner
REM double quotes so it survives the cmd quoting.
:compute_challenge
set COMPUTED_CHALLENGE=
for /f "usebackq delims=" %%c in (`powershell -NoProfile -Command "$s = if ($env:DEVICE_SERIAL) { $env:DEVICE_SERIAL } else { (Get-CimInstance Win32_BIOS).SerialNumber }; $s = $s.Trim().ToUpperInvariant(); if (-not $s) { exit 1 }; $h = New-Object System.Security.Cryptography.HMACSHA256; $h.Key = [Text.Encoding]::UTF8.GetBytes($env:SCEP_PHRASE); [Convert]::ToBase64String($h.ComputeHash([Text.Encoding]::UTF8.GetBytes('device-trust-scep-challenge-v1' + [char]10 + $s)))"`) do set COMPUTED_CHALLENGE=%%c
if not defined COMPUTED_CHALLENGE exit /b 1
exit /b 0

REM ---------------------------------------------------------------------------
REM :run_scep <key-file> <cert-file> <provisioner> <challenge>
REM One scepclient request, tried up to SCEP_ATTEMPTS times. scepclient signs each
REM request with a throwaway certificate whose validity starts "now", and step-ca
REM occasionally rejects a signing time that lands just outside it before the
REM request reaches the webhook. Retrying a request that really was refused is
REM harmless; only an allowed request uses up a phrase. (ping is the sleep: the
REM timeout command fails without an interactive console.)
:run_scep
set SCEP_TRY=1
:run_scep_try
del "%~dp1csr.pem" 2>nul
if not exist "%~1" del "%~dp1self.pem" 2>nul
"%SCEPTOOL%" -private-key "%~1" -certificate "%~2" -server-url "%SCEP_SERVER_URL%/scep/%~3" -challenge "%~4" -dnsname "%DNS_NAME%" -cn "%COMMON_NAME%" -country "%CERT_COUNTRY%" -organization "%CERT_ORGANIZATION%" -ou "%CERT_OU%"
if %errorLevel% equ 0 exit /b 0
if %SCEP_TRY% geq %SCEP_ATTEMPTS% exit /b 1
echo scepclient attempt %SCEP_TRY% of %SCEP_ATTEMPTS% failed - retrying in 2 seconds
set /a SCEP_TRY+=1
ping -n 3 127.0.0.1 >nul
goto :run_scep_try
