#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Windows DUT one-time pre-test setup for automatic-testing-architecture.

.DESCRIPTION
    Bootstraps a fresh Windows installation so it can participate in automated
    power-cycle and reliability tests driven from a Raspberry Pi controller.

    What this script does:
      1. Sets PowerShell execution policy to RemoteSigned (machine-wide)
      2. Installs and enables OpenSSH Server (sshd), autostart on boot
      3. Configures SSH to allow empty-password logins (PermitEmptyPasswords yes)
      4. Opens firewall: TCP 22 (SSH) and ICMPv4 echo (ping)
      5. Disables LimitBlankPasswordUse security policy (allows SSH with no password)
      6. Sets power scheme: no sleep / no hibernate, power button = Shut down
      7. Disables Windows Update automatic reboot
      8. (Optional) Configures auto-logon for the test user account

    This script is intentionally idempotent: running it multiple times is safe.

    IMPORTANT — chicken-and-egg note:
    This script must be run once manually (via physical console, RDP, or a
    shared USB drive) before automated testing can begin.  After it runs and
    the machine reboots, the RPi controller can reach the DUT over SSH for
    all subsequent tests.

.PARAMETER TestUser
    Windows username to configure for auto-logon.
    Leave empty (default) to skip auto-logon setup.
    SSH liveness checks work without auto-logon because sshd is a Windows
    service that starts before user login.

.PARAMETER TestPassword
    Password for TestUser.  May be an empty string "" if the account has no
    password (ensure LimitBlankPasswordUse is disabled — this script does that).

.EXAMPLE
    # Minimal: SSH + firewall + power settings only
    .\setup_dut.ps1

.EXAMPLE
    # With auto-logon for a test account called "testuser"
    .\setup_dut.ps1 -TestUser "testuser" -TestPassword "mypassword"

.EXAMPLE
    # Auto-logon with a passwordless account
    .\setup_dut.ps1 -TestUser "testuser" -TestPassword ""
#>

param(
    [string]$TestUser     = "",
    [string]$TestPassword = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── helpers ───────────────────────────────────────────────────────────────────

function Write-Step { param([string]$Msg)
    Write-Host "`n=== $Msg ===" -ForegroundColor Cyan }

function Write-OK { param([string]$Msg)
    Write-Host "  [OK]   $Msg" -ForegroundColor Green }

function Write-Skip { param([string]$Msg)
    Write-Host "  [SKIP] $Msg" -ForegroundColor DarkGray }

function Write-Warn { param([string]$Msg)
    Write-Host "  [WARN] $Msg" -ForegroundColor Yellow }


# ── 1. PowerShell execution policy ───────────────────────────────────────────

Write-Step "1 / 7  PowerShell execution policy"
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine -Force
Write-OK "Execution policy = RemoteSigned (machine-wide)"


# ── 2. OpenSSH Server ────────────────────────────────────────────────────────

Write-Step "2 / 7  OpenSSH Server"

$sshCap = Get-WindowsCapability -Online -Name OpenSSH.Server*
if ($sshCap.State -eq "NotPresent") {
    Write-Host "  Installing OpenSSH Server capability..."
    Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
    Write-OK "OpenSSH Server installed"
} else {
    Write-Skip "OpenSSH Server already installed"
}

# sshd must be started at least once so Windows creates sshd_config
Start-Service sshd
Set-Service -Name sshd -StartupType Automatic
Write-OK "sshd running, startup = Automatic"


# ── 3. SSH configuration: allow empty passwords ───────────────────────────────

Write-Step "3 / 7  SSH configuration (PermitEmptyPasswords)"

$sshConfigPath = "C:\ProgramData\ssh\sshd_config"

if (-not (Test-Path $sshConfigPath)) {
    Write-Warn "sshd_config not found at $sshConfigPath — skipping"
} else {
    # Backup original (overwrite previous backup so only one .bak is kept)
    Copy-Item -Path $sshConfigPath -Destination "$sshConfigPath.bak" -Force

    $content    = Get-Content $sshConfigPath
    $targetLine = "PermitEmptyPasswords yes"

    if ($content -match "^PermitEmptyPasswords\s+") {
        $content = $content -replace "^PermitEmptyPasswords\s+\S+", $targetLine
        Write-OK "Updated existing PermitEmptyPasswords line"
    } else {
        $content += "`n$targetLine"
        Write-OK "Appended PermitEmptyPasswords yes to sshd_config"
    }

    $content | Set-Content -Path $sshConfigPath -Encoding UTF8
    Restart-Service sshd
    Write-OK "sshd restarted with new configuration"
}


# ── 4. Firewall: SSH (TCP 22) and ICMPv4 ping ─────────────────────────────────

Write-Step "4 / 7  Firewall rules"

# SSH — TCP 22
if (-not (Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name        "OpenSSH-Server-In-TCP" `
                        -DisplayName "OpenSSH Server (sshd)" `
                        -Direction   Inbound `
                        -Protocol    TCP `
                        -LocalPort   22 `
                        -Action      Allow `
                        -Enabled     True | Out-Null
    Write-OK "Firewall rule created: SSH TCP 22"
} else {
    Write-Skip "Firewall rule already exists: SSH TCP 22"
}

# ICMPv4 ping — required for liveness check (power_cycle.py pings DUT)
if (-not (Get-NetFirewallRule -Name "Allow-ICMPv4-In" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name        "Allow-ICMPv4-In" `
                        -DisplayName "Allow ICMPv4 echo (ping) Inbound" `
                        -Protocol    ICMPv4 `
                        -IcmpType    8 `
                        -Direction   Inbound `
                        -Action      Allow `
                        -Enabled     True | Out-Null
    Write-OK "Firewall rule created: ICMPv4 ping"
} else {
    Write-Skip "Firewall rule already exists: ICMPv4 ping"
}


# ── 5. Security policy: allow blank-password accounts over network ────────────

Write-Step "5 / 7  Security policy (LimitBlankPasswordUse)"

$tmpSec = "$env:TEMP\secpol_dut.inf"
secedit /export /cfg $tmpSec | Out-Null

$secContent = Get-Content $tmpSec

# Match both "=4,1" and "= 4, 1" style formatting
$secContent = $secContent -replace `
    '(MACHINE\\System\\CurrentControlSet\\Control\\Lsa\\LimitBlankPasswordUse\s*=\s*4\s*,\s*)1',
    '${1}0'

$secContent | Set-Content $tmpSec -Encoding Unicode
secedit /configure /db secedit.sdb /cfg $tmpSec /areas SECURITYPOLICY | Out-Null
Remove-Item $tmpSec -Force

Write-OK "LimitBlankPasswordUse set to 0 (blank-password SSH logins allowed)"


# ── 6. Power scheme ───────────────────────────────────────────────────────────

Write-Step "6 / 7  Power scheme"

# All timeouts to 0 (never)
foreach ($type in @("monitor", "disk", "standby", "hibernate")) {
    foreach ($mode in @("ac", "dc")) {
        powercfg /change "$type-timeout-$mode" 0
    }
}

# Disable lock-on-resume
powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_NONE CONSOLELOCK 0
powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_NONE CONSOLELOCK 0

# Power button action = Shut down (3), not Sleep (1)
# This ensures ATX soft-off works correctly with the relay
powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_BUTTONS PBUTTONACTION 3
powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_BUTTONS PBUTTONACTION 3

powercfg /S SCHEME_CURRENT

Write-OK "All power timeouts = 0; power button = Shut down; no screen lock on resume"


# ── 7. Windows Update: disable automatic reboot ───────────────────────────────

Write-Step "7 / 7  Windows Update (disable automatic reboot)"

$wuPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
if (-not (Test-Path $wuPath)) {
    New-Item -Path $wuPath -Force | Out-Null
}
# Do not reboot while a user is logged on
Set-ItemProperty -Path $wuPath -Name "NoAutoRebootWithLoggedOnUsers" -Value 1 -Type DWord
# Notify before download (prevents silent installs mid-test)
Set-ItemProperty -Path $wuPath -Name "AUOptions"                     -Value 2 -Type DWord

Write-OK "Windows Update will not auto-reboot during tests"


# ── 8. Auto-logon (optional) ──────────────────────────────────────────────────

Write-Step "8 / 8  Auto-logon"

if ($TestUser -ne "") {
    $regPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
    Set-ItemProperty -Path $regPath -Name "AutoAdminLogon"   -Value "1"
    Set-ItemProperty -Path $regPath -Name "DefaultUserName"  -Value $TestUser
    Set-ItemProperty -Path $regPath -Name "DefaultPassword"  -Value $TestPassword
    Set-ItemProperty -Path $regPath -Name "DefaultDomainName" -Value $env:COMPUTERNAME
    Write-OK "Auto-logon configured for user: $TestUser"
} else {
    Write-Skip "Auto-logon not configured (no -TestUser supplied)"
    Write-Host "         SSH liveness works without auto-logon (sshd is a Windows service)."
    Write-Host "         Pass -TestUser <name> if test scripts need an active user session."
}


# ── Summary ───────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host ("=" * 56) -ForegroundColor Cyan
Write-Host "  DUT Setup Complete" -ForegroundColor Cyan
Write-Host ("=" * 56) -ForegroundColor Cyan
Write-Host "  Execution policy  : RemoteSigned"
Write-Host "  SSH (TCP 22)      : installed + running + firewall open"
Write-Host "  ICMPv4 ping       : firewall open"
Write-Host "  Power scheme      : no sleep / no hibernate"
Write-Host "  Power button      : Shut down"
Write-Host "  Windows Update    : no auto-reboot"
if ($TestUser -ne "") {
    Write-Host "  Auto-logon        : $TestUser"
} else {
    Write-Host "  Auto-logon        : not configured"
}
Write-Host ""
Write-Host "  >>> Reboot required for all changes to take effect. <<<" -ForegroundColor Yellow
Write-Host ("=" * 56) -ForegroundColor Cyan
