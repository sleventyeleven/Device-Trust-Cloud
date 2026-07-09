@echo off
REM Device Trust Certificate Installation Script for Windows
REM This script automates the installation of scepclient and requests a device trust certificate

setlocal enabledelayedexpansion

echo ========================================
echo Device Trust Certificate Installation
echo ========================================
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

REM Set installation directory
set INSTALL_DIR=C:\Program Files\scepclient
set CERT_DIR=%INSTALL_DIR%\certs
set ROOT_CA_FILE=%CERT_DIR%\root-ca.crt
set PRIVATE_KEY_FILE=%CERT_DIR%\client.key
set CERT_FILE=%CERT_DIR%\client.crt
set FULL_CHAIN_FILE=%CERT_DIR%\full-chain.pem

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
echo - Cert Directory: %CERT_DIR%
echo.

REM Download scepclient for Windows
echo Downloading scepclient for Windows...
set SCEPCLIENT_URL=https://github.com/micromdm/scep/releases/latest/download/scepclient-windows-amd64.exe

powershell -Command "& { $ProgressPreference = 'SilentlyContinue'; try { Invoke-WebRequest -Uri '%SCEPCLIENT_URL%' -OutFile '%INSTALL_DIR%\scepclient.exe' -UseBasicParsing; Write-Host 'Downloaded successfully' } catch { Write-Host 'Download failed: ' $_.Exception.Message; exit 1 } }"

if %errorLevel% neq 0 (
    echo Error: Failed to download scepclient
    pause
    exit /b 1
)

REM Make scepclient executable (if not already)
if not exist "%INSTALL_DIR%\scepclient.exe" (
    echo Error: scepclient.exe not found after download
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
) else (
    echo Note: ROOT_CA_URL not set. Please set ROOT_CA_URL environment variable.
    echo The root CA certificate must be manually installed.
)

if exist "%ROOT_CA_FILE%" (
    echo Installing root CA to Trusted Root Certification Authorities store...
    powershell -Command "certutil -addstore 'Root' '%ROOT_CA_FILE%'"
    if %errorLevel% equ 0 (
        echo Root CA installed successfully
    ) else (
        echo Warning: Failed to install root CA, but continuing...
    )
) else (
    echo Warning: Root CA certificate not found, but continuing...
)

REM Request device trust certificate
echo.
echo ========================================
echo Requesting Device Trust Certificate
echo ========================================
echo.

REM Build scepclient command
set SCEPTOOL=%INSTALL_DIR%\scepclient.exe
set SERVER_URL=%SCEP_SERVER_URL%/scep/%SCEP_PROVISIONER%
set DNS_NAME=%HOSTNAME%
set COMMON_NAME=%HOSTNAME%

echo Command:
"%SCEPTOOL%" -private-key "%PRIVATE_KEY_FILE%" -server-url "%SERVER_URL%" -challenge "%SCEP_CHALLENGE%" -dnsname "%DNS_NAME%" -cn "%COMMON_NAME%" -country "%CERT_COUNTRY%" -organization "%CERT_ORGANIZATION%" -ou "%CERT_OU%"

if %errorLevel% neq 0 (
    echo.
    echo Error: Certificate request failed!
    echo Please check your SCEP server URL, challenge, and root CA installation.
    pause
    exit /b 1
)

REM Verify certificate was created
if not exist "%CERT_FILE%" (
    echo Error: Certificate file not created
    pause
    exit /b 1
)

REM Save full certificate chain (CA certificate + device certificate)
if exist "%FULL_CHAIN_FILE%" (
    del "%FULL_CHAIN_FILE%"
)
echo %ROOT_CA_FILE% >> "%FULL_CHAIN_FILE%"
echo %CERT_FILE% >> "%FULL_CHAIN_FILE%"

echo.
echo ========================================
echo Installation Successful!
echo ========================================
echo.
echo Files created:
echo - Private Key: %PRIVATE_KEY_FILE%
echo - Certificate: %CERT_FILE%
echo - Full Chain: %FULL_CHAIN_FILE%
echo.
echo You can now import these certificates into your applications.
echo.

REM Export certificate and private key for easy use
echo Generating PFX file for import...
powershell -Command "$cert = Get-Content '%CERT_FILE%' | certutil -store Root | Select-String -Pattern '%HOSTNAME%'; if ($cert) { Export-Certificate -Cert $cert -FilePath '%CERT_DIR%\client.cer' -Force }"

pause