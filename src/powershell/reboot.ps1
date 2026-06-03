<#
.SYNOPSIS
  DUT-local software reboot endurance test (PWR011).

.DESCRIPTION
  Runs entirely on the DUT - no Pi or control node required.

  STARTING A TEST
    Just run it. Uses the default cycle count if you do not pass -Cycles:
      .\reboot.ps1                 (uses default cycle count)
      .\reboot.ps1 -Cycles 100     (run 100 reboot cycles)

    WARNING: the machine will reboot after a visible countdown.
    Press Ctrl+C during the countdown to cancel.

  DURING THE TEST
    Task Scheduler invokes reboot.ps1 on every startup (registered by
    setup_dut.ps1). Each invocation checks the session file:
      - If a test is in progress (status=running, n < m): record this boot,
        then reboot again (or stop if n has reached m).
      - If no test is in progress: exit silently (normal boot).

  CHECKING PROGRESS (after reboots)
    Open the plain-text status file - it is rewritten after every cycle:
      notepad .\logs\REBOOT_STATUS.txt
    Do NOT run reboot.ps1 to check status: with a test in progress it would
    resume and trigger another reboot.

  STOPPING EARLY
    Delete logs\reboot_session.json. The next boot will not reboot again.

  RESUMING AFTER POWER LOSS
    The session file retains the last completed cycle. Task Scheduler resumes
    automatically on the next boot - no manual action needed.

.EXAMPLE
  .\reboot.ps1
  .\reboot.ps1 -Cycles 50
  .\reboot.ps1 -Cycles 50 -Settle 10
  .\reboot.ps1 -DryRun -Cycles 3
#>

[CmdletBinding()]
param(
    [int]   $Cycles    = 0,     # cycle count; 0 = use default (or resume via Task Scheduler)
    [int]   $Settle    = 30,    # seconds of countdown before each reboot
    [switch]$DryRun             # skip actual Restart-Computer (for testing)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -- Version & defaults --------------------------------------------------------

$_script_ver                = '00.00.05'
$_requires_function_ps1_api = '00.00.01'
$_default_cycles            = 1000   # used when run with no -Cycles and no test in progress

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

function New-RebootSession {
    param([int]$Target)
    $ts = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'
    $sid = Get-Date2
    $s = @{
        session_id = $sid
        test       = 'reboot'
        m          = $Target
        n          = 0
        status     = 'running'
        started_at = $ts
        updated_at = $ts
    }
    Write-SessionJson -Data $s
    Append-CycleLog -SessionId $sid -Line "SESSION_START: $sid  m=$Target  t=$ts"
    Write-StatusFile "REBOOT TEST IN PROGRESS`r`nSession : $sid`r`nTarget  : $Target cycles`r`nDone    : 0 / $Target`r`nStarted : $ts`r`nLog     : $_log_path\reboot_$sid.log"
    return $s
}

# -- Session resolution --------------------------------------------------------
# Rules:
#   -Cycles N (N > 0)         -> always start a NEW session of N cycles
#   no args, test running     -> resume (this is the Task Scheduler boot trigger)
#   no args, no test running  -> start a NEW session of the default cycle count

$session  = Read-SessionJson
$resuming = $false

$runningExists = ($null -ne $session -and
                  $session.status -eq 'running' -and
                  [int]$session.n -lt [int]$session.m)

if ($Cycles -gt 0) {
    $session = New-RebootSession -Target $Cycles
    $sessionId = [string]$session.session_id
    $m = [int]$session.m
    $n = 0
}
elseif ($runningExists) {
    $resuming  = $true
    $sessionId = [string]$session.session_id
    $m         = [int]$session.m
    $n         = [int]$session.n
}
else {
    $session = New-RebootSession -Target $_default_cycles
    $sessionId = [string]$session.session_id
    $m = [int]$session.m
    $n = 0
}

# -- Record this boot (Task Scheduler trigger on resume) -----------------------

if ($resuming) {
    $n++
    $ts    = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'
    $entry = "CYCLE: n=$n/$m  verdict=PASS  t=$ts"   # PASS = booted far enough to run (PWR011)
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
        # Notify the interactive user - msg.exe sends across sessions (SYSTEM -> user desktop)
        try { & msg.exe * "Reboot test COMPLETE: $n / $m cycles PASS  [$sessionId]" 2>$null } catch {}
        exit 0
    }

    Write-SessionJson -Data $session
    Write-StatusFile "REBOOT TEST IN PROGRESS`r`nSession : $sessionId`r`nTarget  : $m cycles`r`nDone    : $n / $m`r`nUpdated : $ts`r`nLog     : $_log_path\reboot_$sessionId.log"
    Write-Host "[reboot] Cycle $n / $m recorded." -ForegroundColor Green
    # Notify the interactive user - msg.exe sends across sessions (SYSTEM -> user desktop)
    try { & msg.exe * "Reboot test: cycle $n / $m PASS - continuing..." 2>$null } catch {}
}
else {
    # Fresh start: show session info (interactive run).
    Write-Host ""
    Write-Host ("[reboot] New session: $sessionId  target=$m cycles") -ForegroundColor Cyan
    Write-Host ("[reboot] Status file: $_status_file") -ForegroundColor Cyan
    Write-Host ("[reboot] Press Ctrl+C to cancel.") -ForegroundColor Yellow
    Write-Host ""
}

# -- Countdown then reboot -----------------------------------------------------

if ($DryRun) {
    Write-Host "[reboot] DRY-RUN: would reboot after $Settle s countdown" -ForegroundColor DarkGray
    exit 0
}

Write-Host -NoNewline "[reboot] Rebooting in: " -ForegroundColor Yellow
for ($i = $Settle; $i -gt 0; $i--) {
    Write-Host -NoNewline ("{0} " -f $i) -ForegroundColor Yellow
    Start-Sleep -Seconds 1
}
Write-Host ""
Restart-Computer -Force
