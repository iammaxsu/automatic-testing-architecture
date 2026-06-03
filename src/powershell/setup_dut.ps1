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
     11. (Optional) Installs Python and creates a one-click HTML report launcher

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

.PARAMETER InstallPython
    When specified, installs Python 3 (via winget) so the DUT can render HTML
    reports locally with report.py. report.py is stdlib-only, so no extra pip
    packages are required. If winget is unavailable, the script prints manual
    install instructions instead of failing.

.PARAMETER ReportScript
    Full path on this machine to report.py (the shared HTML renderer).
    When specified, the script writes a one-click launcher (gen_report.cmd +
    gen_report.ps1) next to reboot.ps1. Double-clicking gen_report.cmd renders
    the newest *.result.json in the logs folder into an HTML report and opens it.
    Leave empty (default) to skip the launcher.

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
    # Install Python and create the one-click report launcher next to reboot.ps1
    .\setup_dut.ps1 -InstallPython `
                    -RebootScript "C:\TestAutomation\powershell\reboot.ps1" `
                    -ReportScript "C:\TestAutomation\python\report.py"

.EXAMPLE
    # Complete lab setup: auto-logon + device detection + reboot task +
    # Ansible SSH + Python + one-click report launcher
    .\setup_dut.ps1 -TestUser "testuser" `
                    -DevDetectScript "C:\TestAutomation\powershell\dev_detect.ps1" `
                    -RebootScript    "C:\TestAutomation\powershell\reboot.ps1" `
                    -ReportScript    "C:\TestAutomation\python\report.py" `
                    -InstallPython -AnsibleSSH
#>

param(
    [string]$TestUser                 = "",
    [string]$TestPassword             = "",
    [string]$DevDetectScript          = "",
    [int]   $DevDetectStartupDelaySec = 30,
    [string]$RebootScript             = "",
    [int]   $RebootStartupDelaySec    = 60,
    [string]$ReportScript             = "",
    [switch]$InstallPython,
    [switch]$AnsibleSSH
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -- Version & shared library --------------------------------------------------

$_script_ver                = '00.00.10'
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
        [int]   $DelaySec
    )
    $absScript = (Resolve-Path -LiteralPath $ScriptPath).Path
    $workDir   = Split-Path -Parent $absScript
    $action    = New-ScheduledTaskAction `
        -Execute          "powershell.exe" `
        -Argument         "-ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File `"$absScript`"" `
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
            -Description "Runs reboot.ps1 at startup to continue an in-progress reboot endurance test" `
            -ScriptPath  $RebootScript `
            -DelaySec    $RebootStartupDelaySec
        Write-OK "Task 'DUT-Reboot' registered (startup + ${RebootStartupDelaySec}s delay, runs as SYSTEM)"
        Write-Host "         Script : $((Resolve-Path -LiteralPath $RebootScript).Path)"
        Write-Host "         NOTE   : reboot.ps1 exits silently when no test is in progress."
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


# -- 11. Python runtime + one-click report generator --------------------------
# report.py (shared renderer) is stdlib-only, so a plain Python install is all
# that is needed to turn any test's result.json into an HTML report on the DUT.

Write-Step "11 / 11  Python runtime + one-click report generator"

# 11a. Install Python (optional).
$pythonReady = $false
$pyCmd = Get-Command python -ErrorAction SilentlyContinue
if ($pyCmd) { $pythonReady = $true }

if ($InstallPython) {
    if ($pythonReady) {
        Write-Skip "Python already installed: $((& python --version 2>&1))"
    } else {
        $wingetCmd = Get-Command winget -ErrorAction SilentlyContinue
        if ($wingetCmd) {
            Write-Host "  Installing Python 3 via winget (silent)..."
            try {
                winget install --exact --id Python.Python.3.12 --silent `
                    --accept-package-agreements --accept-source-agreements --scope machine
            } catch {
                Write-Warn "winget install reported an error: $($_.Exception.Message)"
            }
            # winget updates the machine PATH; this session may not see it yet.
            $machinePath = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
            if ($machinePath) { $env:Path = "$machinePath;$env:Path" }
            $pyCmd = Get-Command python -ErrorAction SilentlyContinue
            if ($pyCmd) {
                $pythonReady = $true
                Write-OK "Python ready: $((& python --version 2>&1))"
            } else {
                Write-Warn "Python installed but not on PATH in this session."
                Write-Host "         Open a NEW console (or reboot) and verify: python --version"
                $pythonReady = $true   # installed; PATH refresh pending
            }
        } else {
            Write-Warn "winget not available - cannot auto-install Python."
            Write-Host "         Install manually from https://www.python.org/downloads/"
            Write-Host "         and tick 'Add python.exe to PATH' during setup."
        }
    }
} else {
    if ($pythonReady) {
        Write-Skip "Python install not requested; existing Python found: $((& python --version 2>&1))"
    } else {
        Write-Skip "Python install not requested (add -InstallPython to install)"
        Write-Host "         report.py needs Python to render HTML reports on the DUT."
    }
}

# 11b. One-click report launcher (optional; needs -ReportScript pointing to report.py).
if ($ReportScript -ne "") {
    if (-not (Test-Path $ReportScript)) {
        Write-Warn "report.py not found: $ReportScript  -  skipping one-click launcher"
        Write-Warn "Copy report.py to the DUT first, then re-run with -ReportScript pointing to it."
    } else {
        $absReport = (Resolve-Path -LiteralPath $ReportScript).Path

        # Logs live next to reboot.ps1 when known; otherwise next to report.py.
        if ($RebootScript -ne "" -and (Test-Path $RebootScript)) {
            $logsDir     = Join-Path (Split-Path -Parent (Resolve-Path -LiteralPath $RebootScript).Path) 'logs'
            $launcherDir = Split-Path -Parent (Resolve-Path -LiteralPath $RebootScript).Path
        } else {
            $logsDir     = Join-Path (Split-Path -Parent $absReport) 'logs'
            $launcherDir = Split-Path -Parent $absReport
        }

        $genPs1 = Join-Path $launcherDir 'gen_report.ps1'
        $genCmd = Join-Path $launcherDir 'gen_report.cmd'

        # Worker script: render the NEWEST *.result.json in $logsDir and open it.
        $ps1Body = @'
# gen_report.ps1 - one-click HTML report generator (created by setup_dut.ps1).
# Renders the newest *.result.json in the logs folder via the shared report.py.
$ErrorActionPreference = 'Stop'
$report = '__REPORT__'
$logs   = '__LOGS__'

if (-not (Test-Path $logs)) { Write-Host "Logs folder not found: $logs"; Read-Host 'Press Enter to close'; exit 1 }
$latest = Get-ChildItem -LiteralPath $logs -Filter '*.result.json' -ErrorAction SilentlyContinue |
          Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $latest) { Write-Host "No *.result.json found in $logs"; Read-Host 'Press Enter to close'; exit 1 }

$html = $latest.FullName -replace '\.result\.json$', '.report.html'
Write-Host "Rendering $($latest.Name) ..."
& python "$report" "$($latest.FullName)" "$html"
if (Test-Path $html) {
    Write-Host "Report: $html"
    Start-Process $html
} else {
    Write-Host 'Report was not produced - is Python installed and on PATH?'
    Read-Host 'Press Enter to close'
}
'@
        $ps1Body = $ps1Body.Replace('__REPORT__', $absReport).Replace('__LOGS__', $logsDir)
        Set-Content -Path $genPs1 -Value $ps1Body -Encoding UTF8

        # Double-clickable wrapper (a .ps1 opens in an editor when double-clicked).
        $cmdBody = "@echo off`r`npowershell -ExecutionPolicy Bypass -NoProfile -File `"%~dp0gen_report.ps1`"`r`n"
        Set-Content -Path $genCmd -Value $cmdBody -Encoding ASCII

        Write-OK "One-click report launcher created:"
        Write-Host "         $genCmd  (double-click to render the newest result.json)"
        Write-Host "         Logs    : $logsDir"
        Write-Host "         report.py: $absReport"
    }
} else {
    Write-Skip "One-click report launcher not configured (add -ReportScript path\to\report.py)"
}


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
    Write-Host "  Task Scheduler    : DUT-Reboot    (startup + ${RebootStartupDelaySec}s, as SYSTEM)"
} else {
    Write-Host "  Task Scheduler    : DUT-Reboot    not configured"
}
if ($AnsibleSSH) {
    Write-Host "  Ansible SSH       : DefaultShell = PowerShell 5.1"
} else {
    Write-Host "  Ansible SSH       : not configured"
}
if ($pythonReady) {
    Write-Host "  Python runtime    : available (report.py can render reports on the DUT)"
} else {
    Write-Host "  Python runtime    : not installed (add -InstallPython)"
}
if ($ReportScript -ne "" -and (Test-Path $ReportScript)) {
    Write-Host "  Report launcher   : gen_report.cmd created (one-click HTML report)"
} else {
    Write-Host "  Report launcher   : not configured (add -ReportScript path\to\report.py)"
}
Write-Host ""
Write-Host "  >>> Reboot required for all changes to take effect. <<<" -ForegroundColor Yellow
Write-Host ("=" * 56) -ForegroundColor Cyan
