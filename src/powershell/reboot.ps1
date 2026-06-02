<#
.SYNOPSIS
  DUT-local software reboot endurance test (PWR011).

.DESCRIPTION
  Runs entirely on the DUT — no Pi or control node required.

  STARTING A TEST
    Run once manually (as Administrator) with -Cycles N:
      powershell -ExecutionPolicy Bypass -File .\reboot.ps1 -Cycles 100

    WARNING: the machine will reboot shortly after this command!
    A 10-second countdown is shown so you can press Ctrl+C to cancel.

  CHECKING STATUS
    Run with no arguments to see current test status without starting anything:
      .\reboot.ps1
    Or read the status file directly:
      Get-Content .\logs\REBOOT_STATUS.txt

  DURING THE TEST
    Task Scheduler invokes reboot.ps1 on every startup (registered by
    setup_dut.ps1). Each invocation checks the session file:
      - If a test is in progress (status=running, n < m): record this boot,
        then reboot again (or stop if n has reached m).
      - If no test is in progress: exit silently (normal boot).

  STOPPING EARLY
    Delete logs\reboot_session.json. The next boot will not trigger a reboot.

  RESUMING AFTER POWER LOSS
    If power fails mid-test, the session file retains the last completed n.
    Task Scheduler will resume automatically on the next boot. No manual
    action needed.

.EXAMPLE
  # Start a 50-cycle test (machine will reboot!)
  powershell -ExecutionPolicy Bypass -File .\reboot.ps1 -Cycles 50

  # Check current status without starting anything
  powershell -ExecutionPolicy Bypass -File .\reboot.ps1

  # Dry-run: verify logic without actually rebooting
  powershell -ExecutionPolicy Bypass -File .\reboot.ps1 -DryRun -Cycles 3
#>

[CmdletBinding()]
param(
    [int]   $Cycles    = 0,     # target cycle count; 0 = status check / Task Scheduler resume
    [int]   $Settle    = 30,    # seconds to wait before rebooting (lets logs flush)
    [switch]$DryRun             # skip actual Restart-Computer (for testing)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -- Version & shared library --------------------------------------------------

$_script_ver                = '00.00.03'
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

$_log_path     = Join-Path $_script_root 'logs'
if (-not (Test-Path $_log_path)) { New-Item -Path $_log_path -ItemType Directory | Out-Null }

$_session_file = Join-Path $_log_path 'reboot_session.json'
$_status_file  = Join-Path $_log_path 'REBOOT_STATUS.txt'

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

function Write-StatusFile {
    param([string]$Content)
    Set-Content -Path $_status_file -Value $Content -Encoding UTF8
}

# -- Session resolution --------------------------------------------------------
# Rule: -Cycles N (N > 0) always starts a NEW session.
#       No arguments (Cycles=0) resumes an existing session (Task Scheduler mode)
#       or shows status if none exists.

$session  = Read-SessionJson
$resuming = $false
$ts       = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'

if ($Cycles -gt 0) {
    # ── Manual start: always create a new session ─────────────────────────────
    $sessionId = Get-Date2
    $m         = $Cycles
    $n         = 0
    $session   = @{
        session_id = $sessionId
        test       = 'reboot'
        m          = $m
        n          = $n
        status     = 'running'
        started_at = $ts
        updated_at = $ts
    }
    Write-SessionJson -Data $session
    Append-CycleLog -SessionId $sessionId -Line "SESSION_START: $sessionId  m=$m  t=$ts"
    Write-StatusFile "REBOOT TEST IN PROGRESS`r`nSession : $sessionId`r`nTarget  : $m cycles`r`nDone    : 0 / $m`r`nStarted : $ts`r`nLog     : $_log_path\reboot_$sessionId.log"

    # Prominent reboot warning with countdown
    Write-Host ""
    Write-Host "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Red
    Write-Host "  !!!   REBOOT TEST STARTING — $m CYCLES PLANNED   !!!" -ForegroundColor Red
    Write-Host "  !!!   This machine will REBOOT in $Settle seconds!    !!!" -ForegroundColor Red
    Write-Host "  !!!   Press Ctrl+C NOW to cancel.                !!!" -ForegroundColor Red
    Write-Host "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Session : $sessionId" -ForegroundColor Cyan
    Write-Host "  Log     : $_log_path\reboot_$sessionId.log" -ForegroundColor Cyan
    Write-Host "  Status  : $_status_file" -ForegroundColor Cyan
    Write-Host ""

}
elseif ($null -ne $session -and
        $session.status -eq 'running' -and
        [int]$session.n -lt [int]$session.m) {
    # ── Task Scheduler / resume mode ─────────────────────────────────────────
    $resuming  = $true
    $sessionId = [string]$session.session_id
    $m         = [int]$session.m
    $n         = [int]$session.n
}
else {
    # ── Status display (no test running, no -Cycles) ──────────────────────────
    if ($null -ne $session) {
        $st = $session.status
        $nn = $session.n; $mm = $session.m
        Write-Host "[reboot] Last session: $($session.session_id)  $nn/$mm  status=$st" -ForegroundColor Cyan
    } else {
        Write-Host "[reboot] No reboot test in progress." -ForegroundColor DarkGray
        Write-Host "         Run:  .\reboot.ps1 -Cycles N   to start a test."
    }
    exit 0
}

# -- Record this boot (Task Scheduler trigger on resume) -----------------------

if ($resuming) {
    $n++
    $verdict = 'PASS'   # PASS = Task Scheduler ran = DUT booted far enough (PWR011)
    $ts      = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'
    $entry   = "CYCLE: n=$n/$m  verdict=$verdict  t=$ts"
    Write-Host "[reboot] $entry" -ForegroundColor Green
    Append-CycleLog -SessionId $sessionId -Line $entry

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
        $session.status = 'complete'
        Write-SessionJson -Data $session
        $summary = "SESSION_COMPLETE: $sessionId  n=$n/$m  t=$ts"
        Write-Host "[reboot] $summary" -ForegroundColor Cyan
        Append-CycleLog -SessionId $sessionId -Line $summary
        Write-StatusFile "REBOOT TEST COMPLETE`r`nSession  : $sessionId`r`nResult   : PASS ($n / $m cycles)`r`nFinished : $ts`r`nLog      : $_log_path\reboot_$sessionId.log"
        exit 0
    }

    Write-StatusFile "REBOOT TEST IN PROGRESS`r`nSession : $sessionId`r`nTarget  : $m cycles`r`nDone    : $n / $m`r`nUpdated : $ts`r`nLog     : $_log_path\reboot_$sessionId.log"
    Write-SessionJson -Data $session
    Write-Host "[reboot] Cycle $n / $m recorded. Next reboot in $Settle s ..." -ForegroundColor Yellow
}

# -- Reboot (or dry-run) -------------------------------------------------------

if ($DryRun) {
    Write-Host "[reboot] DRY-RUN: would Restart-Computer in $Settle s" -ForegroundColor DarkGray
    exit 0
}

Start-Sleep -Seconds $Settle
Restart-Computer -Force
