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
      9. (Optional) Registers Task Scheduler tasks (dev_detect.ps1 + reboot.ps1) at startup
     10. (Optional) Configures PowerShell as the default SSH shell for Ansible
     11. Installs Python 3 and downloads report.py so reboot.ps1 can auto-generate HTML reports

    SSH authentication summary:
      - Blank-password account  : steps 3 + 5 allow password-free SSH login out of the box.
      - Password-protected account: pass -PiSshPublicKey with the Pi's public key; the key is
        installed in administrators_authorized_keys so SSH never prompts for a password.

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

.PARAMETER PiSshPublicKey
    The SSH public key of the Raspberry Pi controller (contents of ~/.ssh/id_rsa.pub
    or ~/.ssh/id_ed25519.pub on the Pi).
    When provided, the key is appended to C:\ProgramData\ssh\administrators_authorized_keys
    so the Pi can SSH into this DUT without any password, regardless of whether the
    Windows account has a password set.
    Obtain the key on the Pi with: cat ~/.ssh/id_ed25519.pub
    (or id_rsa.pub if using RSA keys)

.PARAMETER AnsibleSSH
    When specified, configures PowerShell as the default shell for SSH connections
    by writing to HKLM:\SOFTWARE\OpenSSH (DefaultShell + DefaultShellCommandOption).
    Required for Ansible to manage this DUT via SSH using PowerShell modules.
    In Ansible inventory set: ansible_connection=ssh ansible_shell_type=powershell

.EXAMPLE
    # Minimal: SSH + firewall + power settings only
    .\setup_dut.ps1

.EXAMPLE
    # Blank-password account (no SSH key needed - steps 3+5 already allow it)
    .\setup_dut.ps1 -TestUser "testuser" -TestPassword ""

.EXAMPLE
    # Password-protected account: install Pi SSH key for passwordless login
    .\setup_dut.ps1 -TestUser "testuser" -PiSshPublicKey "ssh-ed25519 AAAA...key... pi@raspberrypi"

.EXAMPLE
    # Full setup including device-detection task at startup
    .\setup_dut.ps1 -TestUser "testuser" -DevDetectScript "C:\TestAutomation\dev_detect.ps1"

.EXAMPLE
    # Enable Ansible management over SSH (lab environment)
    .\setup_dut.ps1 -AnsibleSSH

.EXAMPLE
    # Complete lab setup: auto-logon + device detection + reboot task + Ansible SSH
    .\setup_dut.ps1 -TestUser "testuser" `
                    -DevDetectScript "C:\TestAutomation\powershell\dev_detect.ps1" `
                    -RebootScript    "C:\TestAutomation\powershell\reboot.ps1" `
                    -AnsibleSSH
#>

param(
    [string]$TestUser                 = "",
    [string]$TestPassword             = "",
    [string]$PiSshPublicKey           = "",
    [string]$DevDetectScript          = "",
    [int]   $DevDetectStartupDelaySec = 30,
    [string]$RebootScript             = "",
    [int]   $RebootStartupDelaySec    = 60,
    [switch]$AnsibleSSH
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -- 0. Administrator check (FWK033) -------------------------------------------
# MUST be the first executable action, before any other output, so an operator
# who launched a non-elevated shell sees a single clear error instead of a wall
# of step messages with silently-skipped admin-only operations.  #Requires above
# is a backstop; this explicit IsInRole check is reliable across local and SSH.
$_isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $_isAdmin) {
    Write-Host ""
    Write-Host ("=" * 60) -ForegroundColor Red
    Write-Host "  ERROR: Administrator privileges required." -ForegroundColor Red
    Write-Host ("=" * 60) -ForegroundColor Red
    Write-Host "  setup_dut.ps1 configures the test environment and MUST run" -ForegroundColor Yellow
    Write-Host "  elevated.  NOTHING has been changed." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Local : right-click PowerShell -> 'Run as Administrator'" -ForegroundColor Yellow
    Write-Host "  SSH   : log in as an account in the Administrators group" -ForegroundColor Yellow
    Write-Host ""
    exit 1
}

# -- Version & shared library --------------------------------------------------

$_script_ver                = '00.00.15'
$_requires_function_ps1_api = '00.00.01'

$_script_root = Split-Path -Parent $MyInvocation.MyCommand.Definition
$_fn = Join-Path $_script_root 'function.ps1'
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

Write-Step "1 / 11 PowerShell execution policy"
try {
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine -Force -ErrorAction Stop
    Write-OK "Execution policy = RemoteSigned (machine-wide)"
} catch {
    # A Group Policy (or more specific scope) may override LocalMachine.
    # This is not fatal: the script itself runs fine under -ExecutionPolicy Bypass.
    Write-Warn "Could not set LocalMachine policy (overridden by Group Policy) - continuing"
    Write-Host "         Effective policy: $(Get-ExecutionPolicy)"
}


# -- 2. OpenSSH Server --------------------------------------------------------

Write-Step "2 / 11 OpenSSH Server"

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

Write-Step "3 / 11 SSH configuration (PermitEmptyPasswords)"

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


# -- 3b. SSH key: install Pi public key for passwordless login (optional) ------
#
# For blank-password accounts, steps 3 + 5 (PermitEmptyPasswords + LimitBlankPasswordUse)
# already allow the Pi to SSH in without any credential.  This step is only needed when
# the Windows account has a password.
#
# Windows OpenSSH uses administrators_authorized_keys (not ~/.ssh/authorized_keys) for
# accounts in the Administrators group.  The file needs strict ACL (SYSTEM + Admins only)
# or sshd ignores it.

if ($PiSshPublicKey -ne "") {
    $authDir  = "C:\ProgramData\ssh"
    $authFile = Join-Path $authDir "administrators_authorized_keys"

    if (-not (Test-Path $authDir)) { New-Item -Path $authDir -ItemType Directory -Force | Out-Null }

    # Append the key only if it is not already present (idempotent).
    $existing = @()
    if (Test-Path $authFile) { $existing = @(Get-Content $authFile) }
    if ($existing -notcontains $PiSshPublicKey) {
        Add-Content -Path $authFile -Value $PiSshPublicKey -Encoding UTF8
        Write-OK "Pi SSH public key appended to $authFile"
    } else {
        Write-Skip "Pi SSH public key already present in $authFile"
    }

    # Strict ACL: remove inherited permissions, grant SYSTEM and Administrators full control.
    # Without this sshd (running as SYSTEM) silently ignores the file.
    icacls $authFile /inheritance:r /grant "SYSTEM:(F)" /grant "Administrators:(F)" 2>$null | Out-Null
    Write-OK "administrators_authorized_keys ACL fixed (SYSTEM + Administrators only)"
    Write-Host "         Test from the Pi: ssh $TestUser@$($env:COMPUTERNAME)"
} else {
    Write-Skip "SSH key install skipped (no -PiSshPublicKey supplied)"
    Write-Host "         If the account has no password, steps 3+5 already allow passwordless SSH."
    Write-Host "         If it has a password, pass -PiSshPublicKey `"<content of ~/.ssh/id_ed25519.pub>`""
}


# -- 4. Firewall: SSH (TCP 22) and ICMPv4 ping ---------------------------------

Write-Step "4 / 11 Firewall rules"

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

# Disable Windows Firewall entirely on all profiles (test environment).
# Individual rules above are kept as fallback if firewall is re-enabled by policy.
Set-NetFirewallProfile -All -Enabled False
Write-OK "Windows Firewall disabled (Domain / Private / Public)"


# -- 5. Security policy: allow blank-password accounts over network ------------

Write-Step "5 / 11 Security policy (LimitBlankPasswordUse)"

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

Write-Step "6 / 11 Power scheme"

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

Write-Step "7 / 11 Windows Update (disable automatic reboot)"

$wuPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
if (-not (Test-Path $wuPath)) { New-Item -Path $wuPath -Force | Out-Null }
Set-ItemProperty -Path $wuPath -Name "NoAutoRebootWithLoggedOnUsers" -Value 1 -Type DWord
Set-ItemProperty -Path $wuPath -Name "AUOptions"                     -Value 2 -Type DWord
Write-OK "Windows Update will not auto-reboot during tests"


# -- 8. Auto-logon (optional) --------------------------------------------------

Write-Step "8 / 11 Auto-logon"

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


# -- 9. Task Scheduler: startup tasks (dev_detect + reboot) -------------------

Write-Step "9 / 11 Task Scheduler  -  startup tasks"

# Helper: registers a single startup task as SYSTEM with a delay.
# ScriptPath is resolved to an absolute path: Task Scheduler runs as SYSTEM with
# working directory C:\Windows\System32, so a relative path would never be found.
function Register-StartupTask {
    param(
        [string]$TaskName,
        [string]$Description,
        [string]$ScriptPath,
        [int]   $DelaySec,
        [string]$ScriptArgs = ""    # extra args appended after -File "<script>" (e.g. -Resume)
    )
    $absScript = (Resolve-Path -LiteralPath $ScriptPath).Path
    $workDir   = Split-Path -Parent $absScript
    $argLine   = "-ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File `"$absScript`""
    if ($ScriptArgs -ne "") { $argLine = "$argLine $ScriptArgs" }
    $action    = New-ScheduledTaskAction `
        -Execute          "powershell.exe" `
        -Argument         $argLine `
        -WorkingDirectory $workDir
    $trigger       = New-ScheduledTaskTrigger -AtStartup
    $trigger.Delay = "PT${DelaySec}S"
    $settings  = New-ScheduledTaskSettingsSet `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 10) `
        -MultipleInstances   IgnoreNew `
        -StartWhenAvailable
    $principal = New-ScheduledTaskPrincipal `
        -UserId    "SYSTEM" `
        -LogonType ServiceAccount `
        -RunLevel  Highest
    # The task is registered ENABLED and stays enabled permanently.  Each test
    # script decides for itself whether to act: reboot.ps1 is invoked with
    # -Resume, which resumes a running session and otherwise exits silently, so
    # the always-enabled task never disturbs a normal boot or a Pi-controlled
    # test (BUG0026).
    Register-ScheduledTask `
        -TaskName    $TaskName `
        -Description $Description `
        -Action      $action `
        -Trigger     $trigger `
        -Settings    $settings `
        -Principal   $principal `
        -Force | Out-Null
}

# 9a. dev_detect.ps1
if ($DevDetectScript -ne "") {
    if (-not (Test-Path $DevDetectScript)) {
        Write-Warn "Script not found: $DevDetectScript"
        Write-Warn "Copy dev_detect.ps1 to the DUT first, then re-run with -DevDetectScript pointing to it."
    } else {
        Register-StartupTask `
            -TaskName    "DUT-DevDetect" `
            -Description "Runs dev_detect.ps1 at startup for hardware component verification" `
            -ScriptPath  $DevDetectScript `
            -DelaySec    $DevDetectStartupDelaySec
        Write-OK "Task 'DUT-DevDetect' registered (startup + ${DevDetectStartupDelaySec}s delay, runs as SYSTEM)"
        Write-Host "         Script : $((Resolve-Path -LiteralPath $DevDetectScript).Path)"
    }
} else {
    Write-Skip "DUT-DevDetect not configured (no -DevDetectScript supplied)"
    Write-Host "         Pass -DevDetectScript with the full path to dev_detect.ps1 to register the startup task."
}

# 9b. reboot.ps1
if ($RebootScript -ne "") {
    if (-not (Test-Path $RebootScript)) {
        Write-Warn "Script not found: $RebootScript"
        Write-Warn "Copy reboot.ps1 to the DUT first, then re-run with -RebootScript pointing to it."
    } else {
        Register-StartupTask `
            -TaskName    "DUT-Reboot" `
            -Description "Runs 'reboot.ps1 -Resume' at startup to continue an in-progress reboot endurance test" `
            -ScriptPath  $RebootScript `
            -DelaySec    $RebootStartupDelaySec `
            -ScriptArgs  "-Resume"
        Write-OK "Task 'DUT-Reboot' registered (startup + ${RebootStartupDelaySec}s delay, runs as SYSTEM)"
        Write-Host "         Script  : $((Resolve-Path -LiteralPath $RebootScript).Path)"
        Write-Host "         Action  : reboot.ps1 -Resume"
        Write-Host "         NOTE    : -Resume only continues an in-progress test; it exits silently"
        Write-Host "                   otherwise, so it never disturbs a normal boot or a Pi-controlled test."
    }
} else {
    Write-Skip "DUT-Reboot not configured (no -RebootScript supplied)"
    Write-Host "         Pass -RebootScript with the full path to reboot.ps1 to register the startup task."
}


# -- 10. Ansible SSH: PowerShell as default SSH shell -------------------------

Write-Step "10 / 11  Ansible SSH  -  PowerShell default shell"

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


# -- 11. Python 3 runtime ------------------------------------------------------
# reboot.ps1 calls report.py after every cycle to keep the HTML report current.
# report.py is stdlib-only (no pip packages needed).
#
# Two install paths: winget when present (fast), otherwise download the official
# python.org installer and run it silently. Either way the install is unconditional.

function Install-PythonViaWinget {
    $wingetCmd = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $wingetCmd) { return $false }
    Write-Host "  Installing Python 3 via winget (silent)..."
    try {
        winget install --exact --id Python.Python.3.12 --silent `
            --accept-package-agreements --accept-source-agreements --scope machine
        return $true
    } catch {
        Write-Warn "winget install failed: $($_.Exception.Message)  -  trying direct download"
        return $false
    }
}

function Install-PythonViaDownload {
    # Download the official installer for this machine's architecture and run it
    # silently. python.org keeps every release at this path, so the URL is stable.
    $ver = '3.12.7'
    switch ($env:PROCESSOR_ARCHITECTURE) {
        'ARM64' { $fileName = "python-$ver-arm64.exe" }
        'x86'   { $fileName = "python-$ver.exe" }        # 32-bit installer has no suffix
        default { $fileName = "python-$ver-amd64.exe" }  # AMD64
    }
    $url  = "https://www.python.org/ftp/python/$ver/$fileName"
    $dest = Join-Path $env:TEMP $fileName

    try {
        # PowerShell 5.1 defaults to TLS 1.0/1.1; python.org requires TLS 1.2.
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Write-Host "  Downloading $url ..."
        Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
    } catch {
        Write-Warn "Download failed: $($_.Exception.Message)"
        return $false
    }

    Write-Host "  Running silent install (InstallAllUsers=1 PrependPath=1)..."
    try {
        $p = Start-Process -FilePath $dest `
            -ArgumentList '/quiet InstallAllUsers=1 PrependPath=1 Include_test=0' `
            -Wait -PassThru
        Remove-Item $dest -Force -ErrorAction SilentlyContinue
        if ($p.ExitCode -ne 0) {
            Write-Warn "Python installer returned exit code $($p.ExitCode)"
            return $false
        }
        return $true
    } catch {
        Write-Warn "Installer launch failed: $($_.Exception.Message)"
        return $false
    }
}

Write-Step "11 / 11  Python 3 runtime + report.py renderer"

$pythonReady = $false
$pyCmd = Get-Command python -ErrorAction SilentlyContinue
if ($pyCmd) {
    $pythonReady = $true
    Write-Skip "Python already installed: $((& python --version 2>&1))"
} else {
    $installed = Install-PythonViaWinget
    if (-not $installed) { $installed = Install-PythonViaDownload }

    # Refresh PATH for this session (installers write to the machine PATH).
    $machinePath = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
    if ($machinePath) { $env:Path = "$machinePath;$env:Path" }
    $pyCmd = Get-Command python -ErrorAction SilentlyContinue

    if ($pyCmd) {
        $pythonReady = $true
        Write-OK "Python installed and ready: $((& python --version 2>&1))"
    } elseif ($installed) {
        $pythonReady = $true   # installed; PATH refresh pending - works after reboot
        Write-Warn "Python was installed but is not on PATH in this session."
        Write-Host "         It will be available after the reboot (reboot.ps1 runs post-reboot)."
    } else {
        Write-Warn "Automatic Python install did not succeed."
        Write-Host "         Install manually from https://www.python.org/downloads/"
        Write-Host "         Tick 'Add python.exe to PATH', then re-run this script."
    }
}

# Download report.py alongside the PowerShell scripts so reboot.ps1 can call it
# automatically after each cycle.  report.py is pure stdlib - no pip needed.
# setup_dut.ps1 is the single entry point for the user; it handles both Python
# (the runtime) and report.py (the renderer) in one unconditional step.

function Install-ReportPy {
    param([string]$DestDir)
    $destFile = Join-Path $DestDir 'report.py'
    if (Test-Path $destFile) {
        Write-Skip "report.py already present: $destFile"
        return $true
    }
    $url = 'https://raw.githubusercontent.com/iammaxsu/automatic-testing-architecture/main/src/python/report.py'
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Write-Host "  Downloading report.py from GitHub..."
        Invoke-WebRequest -Uri $url -OutFile $destFile -UseBasicParsing
        Write-OK "report.py downloaded to: $destFile"
        return $true
    } catch {
        Write-Warn "Could not download report.py: $($_.Exception.Message)"
        Write-Host "         Copy src/python/report.py from the repository manually."
        return $false
    }
}

$reportPyReady = Install-ReportPy -DestDir $_script_root


# -- Summary -------------------------------------------------------------------

Write-Host ""
Write-Host ("=" * 56) -ForegroundColor Cyan
Write-Host "  DUT Setup Complete" -ForegroundColor Cyan
Write-Host ("=" * 56) -ForegroundColor Cyan
Write-Host "  Execution policy  : RemoteSigned"
Write-Host "  SSH (TCP 22)      : installed + running + firewall open"
Write-Host "  ICMPv4 ping       : firewall open"
Write-Host "  Windows Firewall  : disabled (all profiles)"
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
    Write-Host "  Task Scheduler    : DUT-DevDetect not configured"
}
if ($RebootScript -ne "" -and (Test-Path $RebootScript)) {
    Write-Host "  Task Scheduler    : DUT-Reboot    (startup + ${RebootStartupDelaySec}s, as SYSTEM, runs 'reboot.ps1 -Resume')"
} else {
    Write-Host "  Task Scheduler    : DUT-Reboot    not configured"
}
if ($PiSshPublicKey -ne "") {
    Write-Host "  Pi SSH key        : installed (administrators_authorized_keys)"
} else {
    Write-Host "  Pi SSH key        : not installed (ok if account has no password)"
}
if ($AnsibleSSH) {
    Write-Host "  Ansible SSH       : DefaultShell = PowerShell 5.1"
} else {
    Write-Host "  Ansible SSH       : not configured"
}
if ($pythonReady) {
    Write-Host "  Python runtime    : available"
} else {
    Write-Host "  Python runtime    : install manually then re-run this script"
}
if ($reportPyReady) {
    Write-Host "  report.py         : present (HTML reports auto-generated after each cycle)"
} else {
    Write-Host "  report.py         : not available - copy from src/python/report.py manually"
}
Write-Host ""
Write-Host "  >>> Reboot required for all changes to take effect. <<<" -ForegroundColor Yellow
Write-Host ("=" * 56) -ForegroundColor Cyan
