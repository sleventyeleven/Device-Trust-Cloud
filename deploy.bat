@echo off
REM Deployment Script for Windows
REM This script helps deploy the Device Trust PKI infrastructure

echo =========================================
echo Device Trust PKI Deployment Script (Windows)
echo =========================================
echo.

REM Configuration
set PROJECT_ID=%1
set REGION=%2
if "%PROJECT_ID%"=="" set PROJECT_ID=gcloud config get-value project --quiet
if "%REGION%"=="" set REGION=us-central1

echo Project: %PROJECT_ID%
echo Region: %REGION%
echo.
echo.

REM Check if Terraform is installed
where terraform >nul 2>&1
if %errorlevel% neq 0 (
    echo Error: Terraform is not installed. Please install Terraform 1.6 or higher.
    pause
    exit /b 1
)

REM Check if gcloud is installed
where gcloud >nul 2>&1
if %errorlevel% neq 0 (
    echo Error: gcloud CLI is not installed. Please install Google Cloud SDK.
    pause
    exit /b 1
)

REM Navigate to the directory
cd /d "%~dp0"

echo Current directory: %CD%
echo.
echo.

REM Initialize Terraform
echo Initializing Terraform...
terraform init -upgrade

REM Create a plan
echo.
echo Creating infrastructure plan...
terraform plan -var="project_id=%PROJECT_ID%" -var="region=%REGION%" -out=plan.tfplan

REM Ask for confirmation
echo.
set /p CONFIRM="Do you want to apply this plan? (yes/no): "

if /i "%CONFIRM%"=="yes" (
    echo Applying infrastructure...
    terraform apply plan.tfplan

    echo.
    echo =========================================
    echo Deployment Complete!
    echo =========================================
    echo.
    echo Outputs:
    terraform output -raw
) else (
    echo Deployment cancelled. Plan saved as plan.tfplan.
    echo You can apply it later with: terraform apply plan.tfplan
)

REM Cleanup
if /i "%CONFIRM%"=="yes" (
    del /f /q plan.tfplan
    echo.
    echo Cleanup: Removed plan.tfplan
)

echo.
echo =========================================
echo Deployment script completed.
echo =========================================
pause