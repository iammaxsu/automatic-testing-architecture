<#
.SYNOPSIS
  DUT-local software reboot endurance test (PWR011).

.DESCRIPTION
  Runs entirely on the DUT — no Pi or control node required.

  STARTING A TEST
    Run once manually (as Administrator) with --cycles N:
      powershell -ExecutionPolicy Bypass -File .\reboot.ps1 --cycles 100

    This creates logs\reboot_session.json and immediately reboots the DUT.
    WARNING: the machine will reboot as soon as this command is executed.

  DURING THE TEST
    Task Scheduler invokes reboot.ps1 on every startup (registered by
    setup_dut.ps1). Each invocation checks the session file:
      - If a test is in progress (status=running, n < m): record this boot,
        then reboot again (or stop if n has reached m).
      - If no test is in progress: exit silently (normal boot).

  STOPPING EARLY
    Delete or rename logs\reboot_session.json, or set status to "stopped"
    in that file. The next boot will not trigger another reboot.

  RESUMING
    If the DUT loses power during a test, run reboot.ps1 manually again.
    If the session file still exists with status=running, it resumes from
    where it left off. Use -NewSession to force a fresh start instead.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\reboot.ps1 -Cycles 50
  powershell -ExecutionPolicy Bypass -File .\reboot.ps1 -Cycles 50 -Settle 10
  powershell -ExecutionPolicy Bypass -File .\reboot.ps1 -DryRun -Cycles 3
#>

[CmdletBinding()]
param(
    [int]   $Cycles    = 0,           # target cycle count (required to start a new test)
    [int]   $Settle    = 30,          # seconds to wait before rebooting (lets logs flush)
    [switch]$NewSession,              # force a new session even if one is in progress
    [switch]$DryRun                   # skip actual Restart-Computer (for testing)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -- Version & shared library --------------------------------------------------

$_script_ver                = '00.00.02'
$_requires_function_ps1_api = '00.00.01'

$_script_root = Split-Path -Parent $MyInvocation.MyCommand.Definition

$_fn = Join-Path $_script_root 'function.ps1'
if (-not (Test-Path $_fn)) { Write-Error "function.ps1 not found at $_fn"; exit 1 }
. $_fn
if ($script:_function_ps1_api -lt $_requires_function_ps1_api) {
    Write-Error "function.ps1 API '$($script:_function_ps1_api)' is too old; need '$_requires_function_ps1_api'"
    exit 1
}

# -- Paths ---------------------------------------------------------------------

$_log_path    = Join-Path $_script_root 'logs'
if (-not (Test-Path $_log_path)) { New-Item -Path $_log_path -ItemType Directory | Out-Null }

$_session_file = Join-Path $_log_path 'reboot_session.json'

# -- Helpers -------------------------------------------------------------------

function Read-SessionJson {
    if (-not (Test-Path $_session_file)) { return $null }
    try { return (Get-Content $_session_file -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { return $null }
}

function Write-SessionJson {
    param([hashtable]$Data)
    $tmp = $_session_file + '.tmp'
    $Data | ConvertTo-Json -Depth 5 | Set-Content -Path $tmp -Encoding UTF8
    Move-Item -Path $tmp -Destination $_session_file -Force
}

function Append-CycleLog {
    param([string]$SessionId, [string]$Line)
    $logFile = Join-Path $_log_path "reboot_$SessionId.log"
    Add-Content -Path $logFile -Value $Line -Encoding UTF8
}

# -- Session resolution --------------------------------------------------------

$session  = Read-SessionJson
$resuming = $false

if ($null -ne $session -and
    $session.status -eq 'running' -and
    [int]$session.n -lt [int]$session.m -and
    -not $NewSession) {
    # An incomplete test is in progress — this is a Task Scheduler trigger on boot.
    $resuming  = $true
    $sessionId = [string]$session.session_id
    $m         = [int]$session.m
    $n         = [int]$session.n
}
elseif ($Cycles -gt 0) {
    # Start a new test session (manual invocation).
    $sessionId = Get-Date2
    $m         = $Cycles
    $n         = 0
    $session   = @{
        session_id = $sessionId
        test       = 'reboot'
        m          = $m
        n          = $n
        status     = 'running'
        started_at = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
        updated_at = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
    }
    Write-SessionJson -Data $session
    Write-Host "[reboot] New session $sessionId  m=$m" -ForegroundColor Cyan
    Append-CycleLog -SessionId $sessionId -Line "SESSION_START: $sessionId  m=$m  started=$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')"
}
else {
    # No session in progress and no --cycles given. Nothing to do.
    # This happens on a normal boot when no reboot test has been started.
    exit 0
}

# -- Record this boot (only on resume, i.e. Task Scheduler trigger) -----------

if ($resuming) {
    $n++
    $verdict = 'PASS'   # PASS = Task Scheduler ran this script (PWR011 criterion)
    $ts      = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'
    $entry   = "CYCLE: n=$n  verdict=$verdict  t=$ts"
    Write-Host "[reboot] $entry" -ForegroundColor Green
    Append-CycleLog -SessionId $sessionId -Line $entry

    # Update session n.
    $session = @{
        session_id = $sessionId
        test       = 'reboot'
        m          = $m
        n          = $n
        status     = 'running'
        started_at = [string]$session.started_at
        updated_at = $ts
    }

    if ($n -ge $m) {
        # Test complete.
        $session.status = 'complete'
        Write-SessionJson -Data $session
        $summary = "SESSION_COMPLETE: $sessionId  n=$n/$m  t=$ts"
        Write-Host "[reboot] $summary" -ForegroundColor Cyan
        Append-CycleLog -SessionId $sessionId -Line $summary
        exit 0
    }

    Write-SessionJson -Data $session
}

# -- Schedule next reboot (if not complete and not dry-run) --------------------

if ($resuming) {
    Write-Host "[reboot] Cycle $n / $m recorded. Next reboot in $Settle s ..." -ForegroundColor Yellow
} else {
    Write-Host "[reboot] Session started. Rebooting in $Settle s to begin cycle 1 / $m ..." -ForegroundColor Yellow
}

if ($DryRun) {
    Write-Host "[reboot] DRY-RUN: would Restart-Computer in $Settle s" -ForegroundColor DarkGray
    exit 0
}

Start-Sleep -Seconds $Settle
Restart-Computer -Force
