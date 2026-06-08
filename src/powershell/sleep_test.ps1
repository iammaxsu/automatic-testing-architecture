<#
.SYNOPSIS
  DUT-local sleep / suspend-resume endurance test (SLP001-SLP005).

.DESCRIPTION
  Runs on the DUT itself.  Detects which ACPI sleep states the system supports
  (S3 = Standby, S4 = Hibernate) and, for each selected state, repeatedly:

    1. sits in Windows for a pre-sleep delay (settle / soak),
    2. arms a SOFTWARE RTC wake timer (Win32 CreateWaitableTimer with the
       resume flag) for a fixed number of seconds,
    3. enters the sleep state (SetSuspendState),
    4. the RTC fires and wakes the DUT; this script resumes and records the
       cycle as PASS (the round-trip wake time is stored as boot_time_sec).

  No external hardware is required - the DUT wakes itself.

  Sleep / resume does NOT terminate this process (unlike a reboot), so a single
  continuous run drives the whole test - there is no Task Scheduler resume dance.
  The trade-off: a hard wake FAILURE leaves the DUT asleep with this process
  suspended, so the DUT-local tool cannot self-record a NO_WAKE.  Use the
  Pi-controlled sleep_test.py when you need an external observer to catch a DUT
  that never wakes.

  TWO MODES
    Continuous (default) - run the full endurance test on the DUT:
      .\sleep_test.ps1                       (auto-detect states, defaults)
      .\sleep_test.ps1 -Cycles 100 -State S3
      .\sleep_test.ps1 -State S3,S4 -PreDelay 30 -WakeAfter 10

    One-shot (-OneShot) - perform exactly ONE sleep+wake and exit.  This is the
    entry point the Pi-controlled sleep_test.py invokes over SSH:
      .\sleep_test.ps1 -OneShot -State S3 -WakeAfter 10

  CONFIGURATION (two methods, parameters win)  - SET001
    1. Config file  : config.ps1 next to this script (or -ConfigFile PATH).
    2. Parameters   : -Cycles, -State, -PreDelay, -WakeAfter (override the file).

  ARTEFACTS (in logs\)  - FWK028: result.json is the canonical source of truth
    sleep_<state>_<session>.result.json   canonical machine-readable result
    sleep_<state>_<session>.log           human-readable per-cycle log
    SLEEP_STATUS.txt                       plain-text progress (rewritten each cycle)
    sleep_<state>_session.json             resume bookkeeping (not the result)

  HTML REPORT (FWK028) - rendered by the shared Python renderer, not here:
    python report.py logs\sleep_<state>_<session>.result.json

.EXAMPLE
  .\sleep_test.ps1
  .\sleep_test.ps1 -Cycles 100 -State S3
  .\sleep_test.ps1 -State S3,S4 -PreDelay 30 -WakeAfter 10
  .\sleep_test.ps1 -OneShot -State S3 -WakeAfter 10
  .\sleep_test.ps1 -Detect
  .\sleep_test.ps1 -NewSession -State S3
#>

[CmdletBinding()]
param(
    [int]    $Cycles    = 0,        # counted cycles per state; 0 = use config/default
    [string] $State     = '',       # 'auto' | 'S3' | 'S4' | 'S3,S4'; '' = use config/default
    [int]    $PreDelay  = -1,       # seconds in Windows before sleeping; -1 = use config/default
    [int]    $WakeAfter = -1,       # RTC wake timer seconds; -1 = use config/default
    [switch] $OneShot,              # perform exactly one sleep+wake then exit (SSH entry point)
    [switch] $Detect,               # just print supported sleep states and exit
    [switch] $NewSession,           # discard a running session and start fresh
    [switch] $Stop,                 # mark any running session stopped
    [switch] $DryRun,               # skip the actual suspend (logic test only)
    [string] $ConfigFile = ''       # path to config.ps1 (default: next to this script)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -- Version & hard defaults ---------------------------------------------------

$_script_ver = '00.00.01'

# Hard defaults (used only when neither a parameter nor the config file supplies a value).
$_def_cycles     = 1000
$_def_states     = 'auto'
$_def_pre_delay  = 30
$_def_wake_after = 10
$_def_settle     = 5

$_script_root = Split-Path -Parent $MyInvocation.MyCommand.Definition

Write-Host "sleep_test.ps1 v$_script_ver" -ForegroundColor Cyan

# -- Config file (method 1) ----------------------------------------------------
# Load side-effect-free defaults from the shared config.ps1 (SET001); the
# $_sleep_* variables defined there feed Get-ConfigValue below.  Parameters
# passed on the command line override these values.

if ($ConfigFile -eq '') { $ConfigFile = Join-Path $_script_root 'config.ps1' }
if (Test-Path $ConfigFile) {
    try {
        . $ConfigFile
        Write-Host "         Loaded config : $ConfigFile" -ForegroundColor DarkGray
    } catch {
        Write-Warning "Could not load config file '$ConfigFile': $($_.Exception.Message)"
    }
}

function Get-ConfigValue {
    param([string]$Name, $Fallback)
    $v = Get-Variable -Name $Name -Scope Script -ErrorAction SilentlyContinue
    if ($null -ne $v -and $null -ne $v.Value -and "$($v.Value)" -ne '') { return $v.Value }
    return $Fallback
}

# -- Parameter resolution (method 2 wins) --------------------------------------
# A parameter takes effect only when explicitly passed; otherwise fall back to
# the config file value, then the hard default.

$cfgCycles    = Get-ConfigValue '_sleep_cycles'         $_def_cycles
$cfgStates    = Get-ConfigValue '_sleep_states'         $_def_states
$cfgPreDelay  = Get-ConfigValue '_sleep_pre_delay_sec'  $_def_pre_delay
$cfgWakeAfter = Get-ConfigValue '_sleep_wake_after_sec' $_def_wake_after
$cfgSettle    = Get-ConfigValue '_sleep_settle_sec'     $_def_settle

$Cycles    = if ($PSBoundParameters.ContainsKey('Cycles'))    { $Cycles }    else { [int]$cfgCycles }
$State     = if ($PSBoundParameters.ContainsKey('State'))     { $State }     else { [string]$cfgStates }
$PreDelay  = if ($PSBoundParameters.ContainsKey('PreDelay'))  { $PreDelay }  else { [int]$cfgPreDelay }
$WakeAfter = if ($PSBoundParameters.ContainsKey('WakeAfter')) { $WakeAfter } else { [int]$cfgWakeAfter }
$Settle    = [int]$cfgSettle

if ($Cycles    -le 0) { $Cycles    = $_def_cycles }
if ($State     -eq '') { $State    = $_def_states }
if ($PreDelay  -lt 0) { $PreDelay  = $_def_pre_delay }
if ($WakeAfter -le 0) { $WakeAfter = $_def_wake_after }

# -- Paths ---------------------------------------------------------------------

$_log_path = Join-Path $_script_root 'logs'
if (-not (Test-Path $_log_path)) { New-Item -Path $_log_path -ItemType Directory | Out-Null }
$_status_file = Join-Path $_log_path 'SLEEP_STATUS.txt'

# -- Small helpers -------------------------------------------------------------

function Now-Iso { Get-Date -Format 'yyyy-MM-ddTHH:mm:ss' }   # extended, local (LOG022)
function Now-Ts  { Get-Date -Format 'yyyyMMddTHHmmss' }       # basic, local (LOG022): filenames

# Write text as UTF-8 WITHOUT a BOM (RFC 8259 / report.py / jq friendly).
function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

function Test-IsAdmin {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object System.Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

# -- Native suspend / RTC wake (Win32) -----------------------------------------

if (-not ([System.Management.Automation.PSTypeName]'SleepNative').Type) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class SleepNative {
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern IntPtr CreateWaitableTimer(IntPtr a, bool manualReset, string name);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool SetWaitableTimer(IntPtr h, ref long dueTime, int period,
        IntPtr callback, IntPtr arg, bool resume);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool CloseHandle(IntPtr h);
    [DllImport("powrprof.dll", SetLastError=true)]
    public static extern bool SetSuspendState(bool hibernate, bool force, bool wakeupEventsDisabled);
}
'@
}

# Best-effort: allow RTC wake timers in the active power plan (needs admin).
function Enable-WakeTimers {
    try {
        $sub = '238c9fa8-0aad-41ed-83f4-97be242c8f20'   # SUB_SLEEP
        $set = 'bd3b718a-0680-4d9d-8ab2-e1d2b4ac806d'   # Allow wake timers
        & powercfg /SETACVALUEINDEX SCHEME_CURRENT $sub $set 1 2>$null
        & powercfg /SETDCVALUEINDEX SCHEME_CURRENT $sub $set 1 2>$null
        & powercfg /SETACTIVE SCHEME_CURRENT 2>$null
    } catch {
        Write-Warning "Could not enable wake timers (admin required): $($_.Exception.Message)"
    }
}

# Best-effort: enable hibernation (needed for S4; needs admin).
function Enable-Hibernate {
    try { & powercfg /hibernate on 2>$null }
    catch { Write-Warning "Could not enable hibernation (admin required): $($_.Exception.Message)" }
}

# Parse `powercfg /a` -> array of supported states among S1/S2/S3/S4/S0.
function Get-SupportedSleepStates {
    $out = (& powercfg /a) 2>$null
    $text = ($out -join "`n")
    $states = New-Object System.Collections.Generic.List[string]
    # Only consider the "available" section (stop at the "not available" header).
    $lines = $text -split "`n"
    $inAvail = $false
    foreach ($ln in $lines) {
        if ($ln -match 'are available on this system') { $inAvail = $true;  continue }
        if ($ln -match 'are not available')            { $inAvail = $false; continue }
        if (-not $inAvail) { continue }
        if ($ln -match '\(S3\)')              { if (-not $states.Contains('S3')) { $states.Add('S3') } }
        elseif ($ln -match 'Hibernate')       { if (-not $states.Contains('S4')) { $states.Add('S4') } }
        elseif ($ln -match '\(S1\)')          { if (-not $states.Contains('S1')) { $states.Add('S1') } }
        elseif ($ln -match '\(S2\)')          { if (-not $states.Contains('S2')) { $states.Add('S2') } }
        elseif ($ln -match 'S0 Low Power Idle'){ if (-not $states.Contains('S0')) { $states.Add('S0') } }
    }
    return $states.ToArray()
}

# Resolve the requested -State selection against what the system supports.
function Resolve-States {
    param([string]$Requested, [string[]]$Supported)
    if ($Requested -ieq 'auto') {
        # auto: every supported state among S3/S4 (the states this test targets).
        $sel = @($Supported | Where-Object { $_ -in @('S3','S4') })
        if ($sel.Count -eq 0) {
            # No S3/S4 - fall back to any available sleep (e.g. S0 modern standby).
            $sel = @($Supported | Where-Object { $_ -in @('S0','S1','S2') })
        }
        return $sel
    }
    $want = @($Requested -split '[,\s]+' | Where-Object { $_ -ne '' } | ForEach-Object { $_.ToUpper() })
    $sel  = @()
    foreach ($w in $want) {
        if ($Supported -contains $w) { $sel += $w }
        else { Write-Warning "Requested sleep state '$w' is NOT supported on this system - skipping." }
    }
    return $sel
}

# Perform exactly one sleep+wake.  Returns when the RTC wake brings the DUT back.
function Invoke-SleepOnce {
    param([string]$SleepState, [int]$WakeSec, [switch]$Simulate)
    $hibernate = ($SleepState -eq 'S4')
    if ($Simulate) {
        Write-Host "[DRY-RUN] would arm wake timer +$WakeSec s and enter $SleepState" -ForegroundColor Yellow
        Start-Sleep -Seconds ([Math]::Min($WakeSec, 3))
        return
    }
    $h = [SleepNative]::CreateWaitableTimer([IntPtr]::Zero, $true, $null)
    if ($h -eq [IntPtr]::Zero) {
        throw "CreateWaitableTimer failed (LastError=$([Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
    }
    try {
        [long]$due = -([long]$WakeSec * 10000000)   # relative time, 100-ns units; negative = relative
        $ok = [SleepNative]::SetWaitableTimer($h, [ref]$due, 0, [IntPtr]::Zero, [IntPtr]::Zero, $true)
        if (-not $ok) {
            throw "SetWaitableTimer failed (LastError=$([Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
        }
        # Suspend now.  The resume flag on the timer brings the system back; this
        # call returns only after the DUT has woken.
        [void][SleepNative]::SetSuspendState($hibernate, $false, $false)
    } finally {
        [void][SleepNative]::CloseHandle($h)
    }
}

# -- Detect-only mode ----------------------------------------------------------

$supported = Get-SupportedSleepStates
Write-Host ("         Supported sleep states: " + ($(if ($supported.Count) { $supported -join ', ' } else { '(none detected)' }))) -ForegroundColor DarkGray

if ($Detect) {
    Write-Host ""
    Write-Host "Supported sleep states on this DUT:"
    if ($supported.Count -eq 0) { Write-Host "  (none detected)" }
    else { $supported | ForEach-Object { Write-Host "  $_" } }
    exit 0
}

# -- One-shot mode (SSH entry point for sleep_test.py) -------------------------

if ($OneShot) {
    if ($State -ieq 'auto' -or $State -eq '') {
        Write-Error "-OneShot requires an explicit -State (e.g. -State S3)."
        exit 2
    }
    $oneState = $State.ToUpper()
    if ($supported -notcontains $oneState -and -not $DryRun) {
        Write-Error "Sleep state '$oneState' is not supported on this system."
        exit 3
    }
    Enable-WakeTimers
    if ($oneState -eq 'S4') { Enable-Hibernate }
    Write-Host "One-shot: state=$oneState wake-after=${WakeAfter}s" -ForegroundColor Cyan
    Invoke-SleepOnce -SleepState $oneState -WakeSec $WakeAfter -Simulate:$DryRun
    Write-Host "One-shot: resumed from $oneState." -ForegroundColor Green
    exit 0
}

# -- Result.json helpers (canonical, FWK028) -----------------------------------

function Get-ResultFile {
    param([string]$St, [string]$SessionId)
    Join-Path $_log_path "sleep_${St}_$SessionId.result.json"
}
function Get-SessionFile {
    param([string]$St)
    Join-Path $_log_path "sleep_${St}_session.json"
}

function New-ResultSkeleton {
    param([string]$St, [string]$SessionId, [int]$Target, [string]$StartedAt)
    @{
        schema_version  = '1.1'
        test_name       = "sleep_$St"
        session_id      = $SessionId
        started_at      = $StartedAt
        ended_at        = $null
        config          = @{
            sleep_state          = $St
            cycles_target        = $Target
            pre_delay_sec        = $PreDelay
            wake_after_sec       = $WakeAfter
            settle_sec           = $Settle
        }
        cycles          = @()
        summary         = @{}
        overall_verdict = 'RUNNING'
    }
}

function Read-Json {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    try { return (Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}
function Write-Json {
    param([string]$Path, $Data)
    $tmp = $Path + '.tmp'
    Write-Utf8NoBom -Path $tmp -Text ($Data | ConvertTo-Json -Depth 8)
    Move-Item -Path $tmp -Destination $Path -Force
}

function Write-Status {
    param([string]$Text)
    Write-Utf8NoBom -Path $_status_file -Text $Text
}

# -- Stop mode -----------------------------------------------------------------

if ($Stop) {
    $any = $false
    foreach ($st in @('S3','S4','S2','S1','S0')) {
        $sf = Get-SessionFile $st
        $s  = Read-Json $sf
        if ($s -and $s.status -eq 'running') {
            $h = @{ session_id=$s.session_id; test=$s.test; state=$st; m=$s.m; n=$s.n;
                    status='stopped'; started_at=$s.started_at; updated_at=(Now-Iso) }
            Write-Json $sf $h
            Write-Host "Marked $st session stopped (was at cycle $($s.n)/$($s.m))." -ForegroundColor Yellow
            $any = $true
        }
    }
    if (-not $any) { Write-Host "No running sleep session to stop." }
    exit 0
}

# -- Continuous mode -----------------------------------------------------------

$selected = Resolve-States -Requested $State -Supported $supported
if ($selected.Count -eq 0) {
    Write-Error "No usable sleep state to test (requested '$State', supported '$($supported -join ',')')."
    exit 4
}

if (-not (Test-IsAdmin)) {
    Write-Warning "Not running as Administrator - enabling wake timers / hibernation may fail."
    Write-Warning "If the DUT does not wake, re-run from an elevated PowerShell (FWK033)."
}

Write-Host ""
Write-Host "Sleep Test (DUT-local)" -ForegroundColor Cyan
Write-Host "  States    : $($selected -join ', ')"
Write-Host "  Cycles    : $Cycles per state"
Write-Host "  Pre-delay : ${PreDelay}s   Wake-after: ${WakeAfter}s   Settle: ${Settle}s"
Write-Host "  Logs      : $_log_path"
if ($DryRun) { Write-Host "  *** DRY-RUN - the DUT will NOT actually suspend ***" -ForegroundColor Yellow }

Enable-WakeTimers
if ($selected -contains 'S4') { Enable-Hibernate }

$overallExit = 0

foreach ($st in $selected) {
    $sessionFile = Get-SessionFile $st
    $prev = Read-Json $sessionFile
    $resuming = ($prev -and $prev.status -eq 'running' -and $prev.n -lt $prev.m -and -not $NewSession)

    if ($resuming) {
        $sessionId = $prev.session_id
        $m         = [int]$prev.m
        $startN    = [int]$prev.n + 1
    } else {
        $sessionId = Now-Ts
        $m         = $Cycles
        $startN    = 1
    }

    $resultFile = Get-ResultFile $st $sessionId
    $logFile    = Join-Path $_log_path "sleep_${st}_$sessionId.log"

    if ($resuming) {
        $result = Read-Json $resultFile
        if (-not $result) { $result = New-ResultSkeleton $st $sessionId $m (Now-Iso) }
    } else {
        $result = New-ResultSkeleton $st $sessionId $m (Now-Iso)
    }

    # Session bookkeeping
    $session = @{ session_id=$sessionId; test="sleep_$st"; state=$st; m=$m; n=($startN-1);
                  status='running'; started_at=(Now-Iso); updated_at=(Now-Iso) }
    Write-Json $sessionFile $session

    Add-Content -Path $logFile -Value ("[{0}] === Sleep test state={1} session={2} m={3} start_n={4}{5} ===" -f `
        (Now-Iso), $st, $sessionId, $m, $startN, $(if ($resuming) { ' (RESUMING)' } else { '' }))

    Write-Host ""
    Write-Host ("--- State $st : $m cycles (session $sessionId$(if($resuming){' RESUMING'}))") -ForegroundColor Cyan

    $passCount = @($result.cycles | Where-Object { $_.verdict -eq 'PASS' }).Count

    for ($n = $startN; $n -le $m; $n++) {
        $rec = [ordered]@{
            n             = $n
            t_start       = (Now-Iso)
            t_sleep_cmd   = $null
            t_online      = $null
            boot_time_sec = $null
            sleep_state   = $st
            verdict       = 'PASS'
            notes         = ''
        }

        # Phase 1: settle in Windows.
        Start-Sleep -Seconds $PreDelay

        # Phase 2+: arm wake timer and suspend; returns after resume.
        $rec.t_sleep_cmd = (Now-Iso)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            Invoke-SleepOnce -SleepState $st -WakeSec $WakeAfter -Simulate:$DryRun
        } catch {
            $sw.Stop()
            $rec.verdict = 'SLEEP_ERROR'
            $rec.notes   = "$($_.Exception.Message)"
            $rec.t_online = (Now-Iso)
            $result.cycles += $rec
            Add-Content -Path $logFile -Value ("[{0}] Cycle {1}/{2} {3}: SLEEP_ERROR - {4}" -f (Now-Iso), $n, $m, $st, $rec.notes)
            Write-Host ("  Cycle {0}/{1} {2}: SLEEP_ERROR - {3}" -f $n, $m, $st, $rec.notes) -ForegroundColor Red
            $overallExit = 1
            break
        }
        $sw.Stop()

        $rec.t_online      = (Now-Iso)
        $rec.boot_time_sec = [Math]::Round($sw.Elapsed.TotalSeconds, 2)
        $passCount++
        $result.cycles += $rec

        # Persist canonical result + session after every cycle (LOG023 / FWK028).
        $result.summary = @{ cycles_target=$m; total_ran=$result.cycles.Count;
                             pass=$passCount; fail=($result.cycles.Count - $passCount); fail_breakdown=@{} }
        $result.overall_verdict = 'RUNNING'
        Write-Json $resultFile $result

        $session.n = $n; $session.updated_at = (Now-Iso)
        Write-Json $sessionFile $session

        Add-Content -Path $logFile -Value ("[{0}] Cycle {1}/{2} {3}: PASS  round-trip={4}s" -f (Now-Iso), $n, $m, $st, $rec.boot_time_sec)
        Write-Status ("Sleep test state=$st  cycle $n / $m  PASS  (round-trip $($rec.boot_time_sec)s)`r`nUpdated: $(Now-Iso)")
        Write-Host ("  Cycle {0}/{1} {2}: PASS  round-trip {3}s" -f $n, $m, $st, $rec.boot_time_sec) -ForegroundColor Green

        # Settle before the next cycle.
        if ($n -lt $m) { Start-Sleep -Seconds $Settle }
    }

    # Finalise this state's session/result.
    $ran = $result.cycles.Count
    if ($session.n -ge $m -and $overallExit -eq 0) { $session.status = 'complete' }
    $session.updated_at = (Now-Iso)
    Write-Json $sessionFile $session

    $result.ended_at = (Now-Iso)
    $fail = $ran - $passCount
    $result.summary = @{ cycles_target=$m; total_ran=$ran; pass=$passCount; fail=$fail; fail_breakdown=@{} }
    if ($fail -eq 0 -and $ran -gt 0) { $result.overall_verdict = 'PASS' }
    elseif ($ran -eq 0)             { $result.overall_verdict = 'NO_DATA' }
    else                            { $result.overall_verdict = 'FAIL' }
    Write-Json $resultFile $result

    Write-Host ("--- State $st done: $($result.overall_verdict)  ($passCount/$ran PASS)") -ForegroundColor Cyan
    Write-Host ("    Result JSON: $resultFile")
    Write-Host ("    Render report: python report.py `"$resultFile`"")

    if ($overallExit -ne 0) { break }
}

exit $overallExit
