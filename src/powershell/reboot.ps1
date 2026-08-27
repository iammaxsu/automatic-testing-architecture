<#
.SYNOPSIS
  DUT-local software reboot endurance test (PWR011).

.DESCRIPTION
  Runs entirely on the DUT - no Pi or control node required.

  STARTING A TEST
    Run with no arguments to start a new test (uses default cycle count) or
    to resume an in-progress test:
      .\reboot.ps1              (start default test, or resume if one is running)
      .\reboot.ps1 -Cycles 100  (start a 100-cycle test, or resume if one is running)

    A RUNNING SESSION ALWAYS WINS (LOG023).  If a session is already in progress
    (status=running, n < m), reboot.ps1 resumes it and the stored target m is
    kept - the -Cycles value is ignored.  To discard the running session and
    start over, add -NewSession:
      .\reboot.ps1 -Cycles 50 -NewSession

    The machine will reboot after a short countdown. Press Ctrl+C to cancel.

  DURING THE TEST
    Task Scheduler invokes 'reboot.ps1 -Resume' on every startup (registered by
    setup_dut.ps1).  The -Resume entry point ONLY resumes:
      - If a test is in progress (status=running, n < m): record this boot
        (verdict PASS = the DUT booted far enough to run the script), then
        reboot again, or stop if n has reached m.
      - If no test is in progress: exit silently.  -Resume NEVER starts a new
        test, so a normal boot - or a Pi-controlled power_cycle.py / reboot.py
        test - is never disturbed (BUG0026).
    After each cycle a msg.exe popup notifies the interactive user.

  ARTEFACTS (in logs\)  - FWK028: result.json is the canonical source of truth
    reboot_<session>.result.json   canonical machine-readable result
    reboot_<session>.log           human-readable per-cycle log
    REBOOT_STATUS.txt              plain-text progress (rewritten each cycle)
    reboot_session.json            resume bookkeeping (not the result)

  HTML REPORT
    The canonical result.json is rendered to HTML by the shared Python
    renderer (run on the DUT if Python is installed, or anywhere later):
      python report.py logs\reboot_<session>.result.json
    Boot time recorded per cycle is the reboot ROUND-TRIP (shutdown + POST +
    boot), the quantity that grows as the DUT degrades. The first cycle has
    no prior reboot to measure against, so its boot time is null.

  CHECKING PROGRESS (after reboots)
    Open the plain-text status file - it is rewritten after every cycle:
      notepad .\logs\REBOOT_STATUS.txt
    Do NOT run reboot.ps1 without -Stop to check status: with a test in
    progress it would resume and trigger another reboot.

  STOPPING A TEST
    Use -Stop to cleanly halt any running test:
      .\reboot.ps1 -Stop
    This marks the session stopped (status=stopped) so the scheduled task's
    -Resume entry point will not pick it up on the next boot.  To start a new
    test afterwards, run -Cycles N.

  RESUMING AFTER POWER LOSS
    The session file retains the last completed cycle. Task Scheduler resumes
    automatically on the next boot via 'reboot.ps1 -Resume' - no manual action
    needed.

  RUNNING WITH PYTHON (reboot.py / run_tests.sh)
    The DUT-Reboot task stays registered and enabled permanently, but its
    -Resume entry point exits silently whenever no DUT-local reboot session is
    in progress.  Pi-controlled tests (reboot.py, power_cycle.py) are therefore
    safe to run at any time without any manual intervention (BUG0026).

.EXAMPLE
  .\reboot.ps1
  .\reboot.ps1 -Cycles 50
  .\reboot.ps1 -Cycles 50 -Settle 10
  .\reboot.ps1 -Cycles 50 -NewSession
  .\reboot.ps1 -DryRun -Cycles 3
  .\reboot.ps1 -Stop
#>

[CmdletBinding()]
param(
    [int]   $Cycles     = 0,    # target cycle count for a NEW session; ignored when resuming
    [int]   $Settle     = 30,   # seconds of countdown before each reboot
    [switch]$Resume,            # Task Scheduler entry point: resume only, never start a new test
    [switch]$NewSession,        # force a brand-new session even if one is already running
    [switch]$Stop,              # cleanly halt any running test
    [switch]$DryRun             # skip actual Restart-Computer (for testing)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -- Version & defaults --------------------------------------------------------

$_script_ver                = '00.00.14'
$_requires_function_ps1_api = '00.00.01'

# Hard fallbacks, used only if config.ps1 is missing or a value is unset.
$_def_cycles     = 1000   # used when run with no -Cycles and no test in progress
$_def_settle_sec = 30     # countdown shown before each reboot fires

$_script_root = Split-Path -Parent $MyInvocation.MyCommand.Definition

$_fn = Join-Path $_script_root 'function.ps1'
if (-not (Test-Path $_fn)) { Write-Error "function.ps1 not found at $_fn"; exit 1 }
. $_fn
if ($script:_function_ps1_api -lt $_requires_function_ps1_api) {
    Write-Error "function.ps1 API '$($script:_function_ps1_api)' is too old; need '$_requires_function_ps1_api'"
    exit 1
}

# -- Config file (SET001) ------------------------------------------------------
# Tunable defaults live in the shared config.ps1 ($_reboot_*); a command-line
# parameter overrides them (it wins only when explicitly passed).  config.ps1 is
# side-effect free, so loading it is safe even on the Task Scheduler -Resume path.
$_cfg_file = Join-Path $_script_root 'config.ps1'
if (Test-Path $_cfg_file) {
    try { . $_cfg_file } catch { Write-Warning "Could not load config.ps1: $($_.Exception.Message)" }
}

function Get-ConfigValue {
    param([string]$Name, $Fallback)
    $v = Get-Variable -Name $Name -Scope Script -ErrorAction SilentlyContinue
    if ($null -ne $v -and $null -ne $v.Value -and "$($v.Value)" -ne '') { return $v.Value }
    return $Fallback
}

$_default_cycles = [int](Get-ConfigValue '_reboot_cycles'     $_def_cycles)
if (-not $PSBoundParameters.ContainsKey('Settle')) {
    $Settle = [int](Get-ConfigValue '_reboot_settle_sec' $_def_settle_sec)
}

# -- Paths ---------------------------------------------------------------------

$_log_path     = Join-Path $_script_root 'logs'
if (-not (Test-Path $_log_path)) { New-Item -Path $_log_path -ItemType Directory | Out-Null }

$_session_file = Join-Path $_log_path 'reboot_session.json'
$_status_file  = Join-Path $_log_path 'REBOOT_STATUS.txt'

# -- Time helpers --------------------------------------------------------------

function Now-Iso { Get-Date -Format 'yyyy-MM-ddTHH:mm:ss' }   # extended, local (LOG022)

# Write text as UTF-8 WITHOUT a BOM. PowerShell 5.1's `Set-Content -Encoding
# UTF8` always prepends a BOM, which is invalid in JSON (RFC 8259) and trips up
# strict parsers (report.py, jq, Ansible). .NET's UTF8Encoding($false) omits it.
function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

# -- JSON helpers (session) ----------------------------------------------------

function Read-SessionJson {
    if (-not (Test-Path $_session_file)) { return $null }
    try { return (Get-Content $_session_file -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { return $null }
}

function Write-SessionJson {
    param([hashtable]$Data)
    $tmp = $_session_file + '.tmp'
    Write-Utf8NoBom -Path $tmp -Text ($Data | ConvertTo-Json -Depth 5)
    Move-Item -Path $tmp -Destination $_session_file -Force
}

# -- JSON helpers (canonical result.json, FWK028) ------------------------------

function Get-ResultFile {
    param([string]$SessionId)
    Join-Path $_log_path "reboot_$SessionId.result.json"
}

function New-ResultSkeleton {
    param([string]$SessionId, [int]$Target, [string]$StartedAt)
    @{
        schema_version  = '1.1'
        test_name       = 'reboot'
        session_id      = $SessionId
        started_at      = $StartedAt
        ended_at        = $null
        config          = @{
            dut_host         = $env:COMPUTERNAME
            cycles_target    = $Target
            boot_timeout_sec = $null
            off_time_sec     = $Settle
            mode             = 'dut-local-reboot'
        }
        cycles          = @()
        summary          = @{}
        overall_verdict = 'RUNNING'
    }
}

function Write-ResultJson {
    param([string]$SessionId, [hashtable]$Result)
    $file = Get-ResultFile -SessionId $SessionId
    $tmp  = $file + '.tmp'
    Write-Utf8NoBom -Path $tmp -Text ($Result | ConvertTo-Json -Depth 8)
    Move-Item -Path $tmp -Destination $file -Force
}

function Read-ResultJson {
    param([string]$SessionId)
    $file = Get-ResultFile -SessionId $SessionId
    if (-not (Test-Path $file)) { return $null }
    try { return (Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { return $null }
}

# Append one PASS cycle to the result, recompute summary, and persist.
function Update-ResultWithCycle {
    param(
        [string]   $SessionId,
        [int]      $N,
        [int]      $Target,
        [string]   $StartedAt,
        [object]   $BootTimeSec,   # [double] or $null
        [bool]     $Complete
    )
    $existing = Read-ResultJson -SessionId $SessionId
    if ($null -eq $existing) {
        $result = New-ResultSkeleton -SessionId $SessionId -Target $Target -StartedAt $StartedAt
        $cycles = @()
    } else {
        # Rebuild as a fresh hashtable so ConvertTo-Json output stays stable.
        $result = New-ResultSkeleton -SessionId $SessionId -Target $Target -StartedAt $existing.started_at
        $cycles = @($existing.cycles)
    }

    $rec = @{
        n             = $N
        t_start       = (Now-Iso)
        t_reboot_cmd  = $null
        boot_time_sec = $BootTimeSec
        verdict       = 'PASS'      # PASS = booted far enough to run the script (PWR011)
        notes         = ''
    }
    $cycles = @($cycles) + $rec
    $result.cycles = $cycles

    $passCount = (@($cycles | Where-Object { $_.verdict -eq 'PASS' })).Count
    $result.summary = @{
        cycles_target  = $Target
        total_ran      = $cycles.Count
        pass           = $passCount
        fail           = ($cycles.Count - $passCount)
        fail_breakdown = @{ NO_BOOT = 0 }
    }

    if ($Complete) {
        $result.ended_at        = (Now-Iso)
        $result.overall_verdict = 'PASS'
    } else {
        $result.overall_verdict = 'RUNNING'
    }

    Write-ResultJson -SessionId $SessionId -Result $result
}

# -- Log / status helpers ------------------------------------------------------

function Append-CycleLog {
    param([string]$SessionId, [string]$Line)
    $logFile = Join-Path $_log_path "reboot_$SessionId.log"
    Add-Content -Path $logFile -Value $Line -Encoding UTF8
}

function Write-StatusFile {
    param([string]$Content)
    Set-Content -Path $_status_file -Value $Content -Encoding UTF8
}

function Notify-User {
    param([string]$Message)
    # msg.exe sends across sessions (SYSTEM -> interactive desktop). Absent on
    # some Windows editions (e.g. Home), so fail silently if it is missing.
    try { & msg.exe * $Message 2>$null } catch {}
}

function Invoke-ReportPy {
    param([string]$SessionId)
    # Regenerate the HTML report from the canonical result.json after every cycle
    # so the user can open logs\reboot_<id>.report.html at any time during or
    # after the test to see current progress. Fails silently if Python or
    # report.py is not found (the test itself continues unaffected).
    $jsonFile = Get-ResultFile -SessionId $SessionId
    if (-not (Test-Path $jsonFile)) { return }

    # Look for report.py next to this script first, then in a sibling python\ folder.
    $rpy = Join-Path $_script_root 'report.py'
    if (-not (Test-Path $rpy)) {
        $rpy = Join-Path (Split-Path -Parent $_script_root) 'python\report.py'
    }
    if (-not (Test-Path $rpy)) { return }

    # Prefer 'python', fall back to the 'py' launcher (often present when
    # 'python' is not on PATH, e.g. right after a python.org install).
    $pyExe  = $null
    $pyArgs = @()
    if (Get-Command python -ErrorAction SilentlyContinue) {
        $pyExe = 'python'
    } elseif (Get-Command py -ErrorAction SilentlyContinue) {
        $pyExe = 'py'; $pyArgs = @('-3')
    }
    if (-not $pyExe) { return }

    try { & $pyExe @pyArgs $rpy $jsonFile 2>$null } catch {}
}

function New-RebootSession {
    param([int]$Target)
    $ts  = Now-Iso
    $sid = Get-Date2
    $s = @{
        session_id     = $sid
        test           = 'reboot'
        m              = $Target
        n              = 0
        status         = 'running'
        started_at     = $ts
        updated_at     = $ts
        last_reboot_at = $null   # set just before each Restart-Computer
    }
    Write-SessionJson -Data $s
    Append-CycleLog -SessionId $sid -Line "SESSION_START: $sid  m=$Target  t=$ts"
    Write-StatusFile "REBOOT TEST IN PROGRESS`r`nSession : $sid`r`nTarget  : $Target cycles`r`nDone    : 0 / $Target`r`nStarted : $ts`r`nLog     : $_log_path\reboot_$sid.log"
    # Create the canonical result skeleton up front.
    $skeleton = New-ResultSkeleton -SessionId $sid -Target $Target -StartedAt $ts
    Write-ResultJson -SessionId $sid -Result $skeleton
    return $s
}

# Persist last_reboot_at then reboot (or simulate under -DryRun).
function Invoke-RebootWithCountdown {
    param([hashtable]$Session)
    $Session.last_reboot_at = (Now-Iso)
    $Session.updated_at     = (Now-Iso)
    Write-SessionJson -Data $Session

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
}

# -- Handle -Stop --------------------------------------------------------------

if ($Stop) {
    $session = Read-SessionJson
    if ($null -ne $session -and $session.status -eq 'running') {
        $n_now = [int]$session.n
        $m_now = [int]$session.m
        $sid   = [string]$session.session_id
        $ts    = Now-Iso

        $stoppedSession = @{
            session_id     = $sid
            test           = 'reboot'
            m              = $m_now
            n              = $n_now
            status         = 'stopped'
            started_at     = [string]$session.started_at
            updated_at     = $ts
            last_reboot_at = if ($session.PSObject.Properties.Name -contains 'last_reboot_at') {
                                 [string]$session.last_reboot_at } else { $null }
        }
        Write-SessionJson -Data $stoppedSession
        Append-CycleLog -SessionId $sid -Line "SESSION_STOPPED: $sid  n=$n_now/$m_now  t=$ts"
        Write-StatusFile ("REBOOT TEST STOPPED`r`nSession : $sid`r`nStopped at: $n_now / $m_now cycles`r`nAt      : $ts`r`n`r`nRun '.\reboot.ps1 -Cycles N' to start a new test.")
        Write-Host "[reboot] Test stopped at cycle $n_now / $m_now  (session: $sid)" -ForegroundColor Yellow
    } else {
        Write-Host "[reboot] No running test to stop." -ForegroundColor Gray
    }
    Write-Host "[reboot] Session marked stopped - the scheduled task will not resume it." -ForegroundColor Gray
    Write-Host "[reboot] Use '.\reboot.ps1 -Cycles N' to start a new test." -ForegroundColor Cyan
    exit 0
}

# -- Session resolution (LOG023) ----------------------------------------------
# A running session ALWAYS wins: if one exists (status=running, n<m) and
# -NewSession was not given, resume it and ignore -Cycles (the stored m wins).
# Only when no running session exists is a new one created.
#
# Entry points:
#   -Resume      Task Scheduler boot trigger.  Resume a running session; if none
#                exists, exit silently.  NEVER starts a new test.  This keeps the
#                always-enabled task from interfering with Pi-controlled tests
#                (power_cycle.py / reboot.py) - see BUG0026.
#   -Cycles N    Human start.  Resume if a session is running (m unchanged, LOG023),
#                otherwise start a new N-cycle session.
#   (no args)    Human start.  Resume if a session is running, otherwise start a
#                new session with the default cycle count.
#   -NewSession  Force a brand-new session even if one is already running.

$session  = Read-SessionJson
$resuming = $false

$runningExists = ($null -ne $session -and
                  $session.status -eq 'running' -and
                  [int]$session.n -lt [int]$session.m)

if ($runningExists -and -not $NewSession) {
    # Resume the in-progress session.  -Cycles is ignored: stored m wins (LOG023).
    if ($Cycles -gt 0 -and $Cycles -ne [int]$session.m) {
        Write-Host "[reboot] Resuming session (m=$([int]$session.m)); ignoring -Cycles $Cycles. Use -NewSession to start over." -ForegroundColor Yellow
    }
    $resuming  = $true
    $sessionId = [string]$session.session_id
    $m         = [int]$session.m
    $n         = [int]$session.n
}
elseif ($Resume) {
    # Task Scheduler trigger with no running session: nothing to do.  Exit quietly
    # so a normal boot (or a Pi-controlled test) is never disturbed.
    exit 0
}
elseif ($Cycles -gt 0) {
    # Human start with an explicit target and no running session.
    $session   = New-RebootSession -Target $Cycles
    $sessionId = [string]$session.session_id
    $m         = [int]$session.m
    $n         = 0
}
else {
    # Human start with no target and no running session: use the default.
    $session   = New-RebootSession -Target $_default_cycles
    $sessionId = [string]$session.session_id
    $m         = [int]$session.m
    $n         = 0
}

# -- Record this boot (Task Scheduler trigger on resume) -----------------------

if ($resuming) {
    $n++
    $ts = Now-Iso

    # Reboot round-trip = now - time the previous reboot was issued.
    # Guard the property access: a session written by an older reboot.ps1 may
    # not have last_reboot_at, and StrictMode throws on missing properties.
    $bootTime = $null
    $lastReboot = $null
    if ($session.PSObject.Properties.Name -contains 'last_reboot_at') {
        $lastReboot = $session.last_reboot_at
    }
    if ($lastReboot -and -not [string]::IsNullOrWhiteSpace([string]$lastReboot)) {
        try {
            $delta = ([datetime]::Now - [datetime]::Parse([string]$lastReboot)).TotalSeconds
            if ($delta -ge 0) { $bootTime = [math]::Round($delta, 2) }
        } catch { $bootTime = $null }
    }

    $btText = if ($null -eq $bootTime) { 'n/a' } else { "${bootTime}s" }
    $entry  = "CYCLE: n=$n/$m  verdict=PASS  boot=$btText  t=$ts"
    Write-Host "[reboot] $entry" -ForegroundColor Green
    Append-CycleLog -SessionId $sessionId -Line $entry

    $complete = ($n -ge $m)
    Update-ResultWithCycle -SessionId $sessionId -N $n -Target $m `
        -StartedAt ([string]$session.started_at) -BootTimeSec $bootTime -Complete $complete

    $statusVal = 'running'
    if ($complete) { $statusVal = 'complete' }
    $updatedSession = @{
        session_id     = $sessionId
        test           = 'reboot'
        m              = $m
        n              = $n
        status         = $statusVal
        started_at     = [string]$session.started_at
        updated_at     = $ts
        last_reboot_at = $null
    }
    Write-SessionJson -Data $updatedSession

    if ($complete) {
        $summary = "SESSION_COMPLETE: $sessionId  n=$n/$m  t=$ts"
        Write-Host "[reboot] $summary" -ForegroundColor Cyan
        Append-CycleLog -SessionId $sessionId -Line $summary
        Write-StatusFile "REBOOT TEST COMPLETE`r`nSession  : $sessionId`r`nResult   : PASS ($n / $m cycles)`r`nFinished : $ts`r`nLog      : $_log_path\reboot_$sessionId.log"
        Invoke-ReportPy -SessionId $sessionId
        Notify-User "Reboot test COMPLETE: $n / $m cycles PASS  [$sessionId]"
        exit 0
    }

    Write-StatusFile "REBOOT TEST IN PROGRESS`r`nSession : $sessionId`r`nTarget  : $m cycles`r`nDone    : $n / $m`r`nUpdated : $ts`r`nLog     : $_log_path\reboot_$sessionId.log"
    Write-Host "[reboot] Cycle $n / $m recorded." -ForegroundColor Green
    Invoke-ReportPy -SessionId $sessionId
    Notify-User "Reboot test: cycle $n / $m PASS - continuing..."

    Invoke-RebootWithCountdown -Session $updatedSession
}
else {
    # Fresh start: show session info (interactive run), then reboot.
    Write-Host ""
    Write-Host ("[reboot] New session: $sessionId  target=$m cycles") -ForegroundColor Cyan
    Write-Host ("[reboot] Status file: $_status_file") -ForegroundColor Cyan
    Write-Host ("[reboot] Press Ctrl+C to cancel.") -ForegroundColor Yellow
    Write-Host ""

    $startSession = @{
        session_id     = $sessionId
        test           = 'reboot'
        m              = $m
        n              = 0
        status         = 'running'
        started_at     = [string]$session.started_at
        updated_at     = (Now-Iso)
        last_reboot_at = $null
    }
    Invoke-RebootWithCountdown -Session $startSession
}
