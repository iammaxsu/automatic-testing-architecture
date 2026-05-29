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
      9. (Optional) Registers Task Scheduler task to run dev_detect.ps1 at startup
     10. (Optional) Configures PowerShell as the default SSH shell for Ansible

    This script is intentionally idempotent: running it multiple times is safe.

    IMPORTANT  -  chicken-and-egg note:
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
    password (ensure LimitBlankPasswordUse is disabled  -  this script does that).

.PARAMETER DevDetectScript
    Full path on this machine to dev_detect.ps1.
    When specified, a Task Scheduler task named "DUT-DevDetect" is registered
    to run the script automatically at every startup.
    The task runs as SYSTEM  -  no user login is required.
    Leave empty (default) to skip Task Scheduler setup.

.PARAMETER DevDetectStartupDelaySec
    Seconds to wait after boot before running dev_detect.ps1 (default: 30).
    Increase if your hardware takes longer to fully enumerate devices.

.PARAMETER AnsibleSSH
    When specified, configures PowerShell as the default shell for SSH connections
    by writing to HKLM:\SOFTWARE\OpenSSH (DefaultShell + DefaultShellCommandOption).
    Required for Ansible to manage this DUT via SSH using PowerShell modules.
    In Ansible inventory set: ansible_connection=ssh ansible_shell_type=powershell

.EXAMPLE
    # Minimal: SSH + firewall + power settings only
    .\setup_dut.ps1

.EXAMPLE
    # With auto-logon for a test account called "testuser"
    .\setup_dut.ps1 -TestUser "testuser" -TestPassword "mypassword"

.EXAMPLE
    # Auto-logon with a passwordless account
    .\setup_dut.ps1 -TestUser "testuser" -TestPassword ""

.EXAMPLE
    # Full setup including device-detection task at startup
    .\setup_dut.ps1 -TestUser "testuser" -DevDetectScript "C:\TestAutomation\dev_detect.ps1"

.EXAMPLE
    # Enable Ansible management over SSH (lab environment)
    .\setup_dut.ps1 -AnsibleSSH

.EXAMPLE
    # Complete lab setup: auto-logon + device detection + Ansible SSH
    .\setup_dut.ps1 -TestUser "testuser" -DevDetectScript "C:\TestAutomation\dev_detect.ps1" -AnsibleSSH
#>

param(
    [string]$TestUser                 = "",
    [string]$TestPassword             = "",
    [string]$DevDetectScript          = "",
    [int]   $DevDetectStartupDelaySec = 30,
    [switch]$AnsibleSSH
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -- Version & shared library --------------------------------------------------

$_script_ver                = '00.00.05'
$_requires_function_ps1_api = '00.00.01'

$_fn = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Definition) 'function.ps1'
if (-not (Test-Path $_fn)) {
    Write-Error "function.ps1 not found at $_fn  -  cannot continue"
    exit 1
}
. $_fn
if ($script:_function_ps1_api -lt $_requires_function_ps1_api) {
    Write-Error "function.ps1 API '$($script:_function_ps1_api)' is too old; need '$_requires_function_ps1_api'"
    exit 1
}

Write-Host "setup_dut.ps1 v$_script_ver  (function.ps1 API $($script:_function_ps1_api))"


# -- 1. PowerShell execution policy -------------------------------------------

Write-Step "1 / 10 PowerShell execution policy"
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine -Force
Write-OK "Execution policy = RemoteSigned (machine-wide)"


# -- 2. OpenSSH Server --------------------------------------------------------

Write-Step "2 / 10 OpenSSH Server"

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


# -- 3. SSH configuration: allow empty passwords -------------------------------

Write-Step "3 / 10 SSH configuration (PermitEmptyPasswords)"

$sshConfigPath = "C:\ProgramData\ssh\sshd_config"

if (-not (Test-Path $sshConfigPath)) {
    Write-Warn "sshd_config not found at $sshConfigPath  -  skipping"
} else {
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


# -- 4. Firewall: SSH (TCP 22) and ICMPv4 ping ---------------------------------

Write-Step "4 / 10 Firewall rules"

if (-not (Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name        "OpenSSH-Server-In-TCP" `
                        -DisplayName "OpenSSH Server (sshd)" `
                        -Direction   Inbound -Protocol TCP `
                        -LocalPort   22 -Action Allow -Enabled True | Out-Null
    Write-OK "Firewall rule created: SSH TCP 22"
} else {
    Write-Skip "Firewall rule already exists: SSH TCP 22"
}

if (-not (Get-NetFirewallRule -Name "Allow-ICMPv4-In" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name        "Allow-ICMPv4-In" `
                        -DisplayName "Allow ICMPv4 echo (ping) Inbound" `
                        -Protocol    ICMPv4 -IcmpType 8 `
                        -Direction   Inbound -Action Allow -Enabled True | Out-Null
    Write-OK "Firewall rule created: ICMPv4 ping"
} else {
    Write-Skip "Firewall rule already exists: ICMPv4 ping"
}


# -- 5. Security policy: allow blank-password accounts over network ------------

Write-Step "5 / 10 Security policy (LimitBlankPasswordUse)"

$tmpSec = "$env:TEMP\secpol_dut.inf"
secedit /export /cfg $tmpSec | Out-Null
$secContent = Get-Content $tmpSec
$secContent = $secContent -replace `
    '(MACHINE\\System\\CurrentControlSet\\Control\\Lsa\\LimitBlankPasswordUse\s*=\s*4\s*,\s*)1',
    '${1}0'
$secContent | Set-Content $tmpSec -Encoding Unicode
secedit /configure /db secedit.sdb /cfg $tmpSec /areas SECURITYPOLICY | Out-Null
Remove-Item $tmpSec -Force
Write-OK "LimitBlankPasswordUse set to 0 (blank-password SSH logins allowed)"


# -- 6. Power scheme -----------------------------------------------------------

Write-Step "6 / 10 Power scheme"

foreach ($type in @("monitor", "disk", "standby", "hibernate")) {
    foreach ($mode in @("ac", "dc")) {
        powercfg /change "$type-timeout-$mode" 0
    }
}
powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_NONE    CONSOLELOCK   0
powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_NONE    CONSOLELOCK   0
powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_BUTTONS PBUTTONACTION 3
powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_BUTTONS PBUTTONACTION 3
powercfg /S SCHEME_CURRENT
Write-OK "All power timeouts = 0; power button = Shut down; no screen lock on resume"


# -- 7. Windows Update: disable automatic reboot -------------------------------

Write-Step "7 / 10 Windows Update (disable automatic reboot)"

$wuPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
if (-not (Test-Path $wuPath)) { New-Item -Path $wuPath -Force | Out-Null }
Set-ItemProperty -Path $wuPath -Name "NoAutoRebootWithLoggedOnUsers" -Value 1 -Type DWord
Set-ItemProperty -Path $wuPath -Name "AUOptions"                     -Value 2 -Type DWord
Write-OK "Windows Update will not auto-reboot during tests"


# -- 8. Auto-logon (optional) --------------------------------------------------

Write-Step "8 / 10 Auto-logon"

if ($TestUser -ne "") {
    $regPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
    Set-ItemProperty -Path $regPath -Name "AutoAdminLogon"    -Value "1"
    Set-ItemProperty -Path $regPath -Name "DefaultUserName"   -Value $TestUser
    Set-ItemProperty -Path $regPath -Name "DefaultPassword"   -Value $TestPassword
    Set-ItemProperty -Path $regPath -Name "DefaultDomainName" -Value $env:COMPUTERNAME
    Write-OK "Auto-logon configured for user: $TestUser"
} else {
    Write-Skip "Auto-logon not configured (no -TestUser supplied)"
    Write-Host "         SSH liveness works without auto-logon (sshd is a Windows service)."
    Write-Host "         Pass -TestUser USERNAME if test scripts need an active user session."
}


# -- 9. Task Scheduler: run dev_detect.ps1 at every startup -------------------

Write-Step "9 / 10 Task Scheduler  -  device detection at startup"

if ($DevDetectScript -ne "") {
    if (-not (Test-Path $DevDetectScript)) {
        Write-Warn "Script not found: $DevDetectScript"
        Write-Warn "Copy dev_detect.ps1 to the DUT first, then re-run with -DevDetectScript pointing to it"
    } else {
        $taskAction = New-ScheduledTaskAction `
            -Execute  "powershell.exe" `
            -Argument "-ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File `"$DevDetectScript`""

        $taskTrigger       = New-ScheduledTaskTrigger -AtStartup
        $taskTrigger.Delay = "PT${DevDetectStartupDelaySec}S"

        $taskSettings = New-ScheduledTaskSettingsSet `
            -ExecutionTimeLimit (New-TimeSpan -Minutes 10) `
            -MultipleInstances   IgnoreNew `
            -StartWhenAvailable

        $taskPrincipal = New-ScheduledTaskPrincipal `
            -UserId    "SYSTEM" `
            -LogonType ServiceAccount `
            -RunLevel  Highest

        Register-ScheduledTask `
            -TaskName    "DUT-DevDetect" `
            -Description "Runs dev_detect.ps1 at startup for power-cycle / reboot hardware verification" `
            -Action      $taskAction `
            -Trigger     $taskTrigger `
            -Settings    $taskSettings `
            -Principal   $taskPrincipal `
            -Force | Out-Null

        Write-OK "Task 'DUT-DevDetect' registered (startup + ${DevDetectStartupDelaySec}s delay, runs as SYSTEM)"
        Write-Host "         Script : $DevDetectScript"
    }
} else {
    Write-Skip "Task Scheduler not configured (no -DevDetectScript supplied)"
    Write-Host "         Pass -DevDetectScript with the full path to dev_detect.ps1 to register the startup task."
}


# -- 10. Ansible SSH: PowerShell as default SSH shell -------------------------

Write-Step "10 / 10  Ansible SSH  -  PowerShell default shell"

if ($AnsibleSSH) {
    $regPath = "HKLM:\SOFTWARE\OpenSSH"
    if (-not (Test-Path $regPath)) {
        New-Item -Path $regPath -Force | Out-Null
    }
    # DefaultShell: PowerShell 5.1 (built-in on all Windows 10/11/IoT)
    Set-ItemProperty -Path $regPath -Name "DefaultShell" `
        -Value "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -Type String -Force
    # DefaultShellCommandOption: -Command passes a command string to PowerShell
    Set-ItemProperty -Path $regPath -Name "DefaultShellCommandOption" `
        -Value "-Command" `
        -Type String -Force
    Restart-Service sshd
    Write-OK "DefaultShell = PowerShell 5.1; sshd restarted"
    Write-Host "         Ansible inventory: ansible_connection=ssh ansible_shell_type=powershell"
} else {
    Write-Skip "Ansible SSH not configured (add -AnsibleSSH to enable)"
}


# -- Summary -------------------------------------------------------------------

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
if ($DevDetectScript -ne "" -and (Test-Path $DevDetectScript)) {
    Write-Host "  Task Scheduler    : DUT-DevDetect (startup + ${DevDetectStartupDelaySec}s, as SYSTEM)"
} else {
    Write-Host "  Task Scheduler    : not configured"
}
if ($AnsibleSSH) {
    Write-Host "  Ansible SSH       : DefaultShell = PowerShell 5.1"
} else {
    Write-Host "  Ansible SSH       : not configured"
}
Write-Host ""
Write-Host "  >>> Reboot required for all changes to take effect. <<<" -ForegroundColor Yellow
Write-Host ("=" * 56) -ForegroundColor Cyan
