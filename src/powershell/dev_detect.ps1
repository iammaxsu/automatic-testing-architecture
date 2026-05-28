# Get the directory where the script is located
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

# Define log directory path
$logPath = Join-Path $scriptDir "logs"

# Create the log directory if it doesn't exist
if (-not (Test-Path -Path $logPath)) {
    New-Item -ItemType Directory -Path $logPath | Out-Null
}

# Path to the config variable file
$configVarsPath = Join-Path $logPath "config_vars.txt"
$configScriptPath = Join-Path $scriptDir "config.ps1"

# If config_vars.txt does not exist, run config.ps1 to generate it
if (-not (Test-Path $configVarsPath)) {
    if (Test-Path $configScriptPath) {
        Write-Host "Running config.ps1 to generate config_vars.txt..."
        & $configScriptPath
    } else {
        Write-Host "Missing config.ps1: $configScriptPath"
        exit 1
    }
}

# Now import the config variables
if (Test-Path $configVarsPath) {
    Get-Content $configVarsPath | ForEach-Object {
        if ($_ -match '^\$(.+?)=(.+)$') {
            Set-Variable -Name $matches[1] -Value $matches[2]
        }
    }
} else {
    Write-Host "Failed to generate config_vars.txt"
    exit 1
}

# Sample usage of loaded variables
Write-Host "Log Path: $_logPath"
Write-Host "Counter File: $_counter"
Write-Host "Date1: $_date1"
Write-Host "Date2: $_date2"
Write-Host "Golden File Name: $_gFile"

# Optional logging
"$($_date2) $_counter started" | Out-File -Append "$_logPath\run.log"
