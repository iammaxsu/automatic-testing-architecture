<#
.SYNOPSIS
  DET013 automated test harness for dev_detect.ps1 (the Windows side).

.DESCRIPTION
  Mirrors src/bash-shell/test_dev_detect.sh. Exercises the contract in
  requirements/DET013.md: -Help, the INIT -> Pass -> Fail result sequence,
  the four-state exit code, the JSON sidecar (result / mode / m / components),
  and the snapshot-vs-standalone `mode` field.

  Safety note: unlike dev_detect.sh, dev_detect.ps1 never reboots, powers
  off, or installs/modifies a scheduled task by itself (that is setup_dut.ps1's
  job, and repetition across boots is driven by the Task Scheduler entry it
  registers). So this harness needs no command mocking. Isolation is achieved
  instead by copying the script + function.ps1 (+ config.ps1) into a fresh
  temp folder per scenario and running there, so the real repo's logs\ and
  golden files are never touched.

  Known gap (same as the bash harness): the Error (exit 2) outcome is not
  exercised. It would require a hardware check to throw, which is not
  reproducible on demand without faulting a CIM/WMI provider.

.EXAMPLE
  # From an elevated PowerShell (admin), in src\powershell:
  powershell -NoProfile -ExecutionPolicy Bypass -File .\test_dev_detect.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:_pass = 0
$script:_fail = 0
$script:_tempdirs = @()

function Write-Section { param([string]$Title) Write-Host ''; Write-Host "== $Title ==" }
function Pass-Assert   { param([string]$Msg) $script:_pass++; Write-Host "  [OK] $Msg" }
function Fail-Assert   { param([string]$Msg) $script:_fail++; Write-Host "  [FAIL] $Msg" }

function Assert-Eq {
    param([string]$Desc, $Expected, $Actual)
    if ([string]$Expected -eq [string]$Actual) { Pass-Assert "$Desc (got $Actual)" }
    else { Fail-Assert "$Desc (expected $Expected, got $Actual)" }
}
function Assert-Contains {
    param([string]$Desc, [string]$Haystack, [string]$Needle)
    if ($Haystack -like "*$Needle*") { Pass-Assert $Desc }
    else { Fail-Assert "$Desc (missing: $Needle)" }
}

function New-WorkDir {
    $name = 'devdetect_test_{0}' -f ([guid]::NewGuid().ToString('N').Substring(0, 8))
    $dir  = Join-Path $env:TEMP $name
    New-Item -ItemType Directory -Path $dir | Out-Null
    foreach ($f in 'dev_detect.ps1', 'function.ps1', 'config.ps1') {
        $src = Join-Path $PSScriptRoot $f
        if (Test-Path $src) { Copy-Item -Path $src -Destination $dir }
    }
    $script:_tempdirs += $dir
    return $dir
}

function Invoke-DevDetect {
    # Runs the copied dev_detect.ps1 as a child process so its `exit N` lands
    # in $LASTEXITCODE. Returns an object with .Code and .Out.
    param([string]$WorkDir, [string[]]$ScriptArgs = @())
    $script = Join-Path $WorkDir 'dev_detect.ps1'
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script @ScriptArgs 2>&1 | Out-String
    return [PSCustomObject]@{ Code = $LASTEXITCODE; Out = $out }
}

function Get-LatestSidecar {
    param([string]$WorkDir)
    $logs = Join-Path $WorkDir 'logs'
    if (-not (Test-Path $logs)) { return $null }
    $j = Get-ChildItem -Path $logs -Filter '*.json' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime | Select-Object -Last 1
    if (-not $j) { return $null }
    return (Get-Content -Raw -Path $j.FullName | ConvertFrom-Json)
}

try {
    # -----------------------------------------------------------------------
    Write-Section '-Help'
    $w = New-WorkDir
    $r = Invoke-DevDetect -WorkDir $w -ScriptArgs @('-Help')
    Assert-Eq       '-Help exits 0' 0 $r.Code
    Assert-Contains '-Help lists -SnapshotOnly' $r.Out '-SnapshotOnly'
    Assert-Contains '-Help lists exit codes'    $r.Out 'INIT'
    if (Test-Path (Join-Path $w 'logs')) {
        Fail-Assert '-Help did not create a logs dir'
    } else {
        Pass-Assert '-Help did not create a logs dir'
    }

    # -----------------------------------------------------------------------
    Write-Section '--help (Unix alias) behaves like -Help'
    $wh = New-WorkDir
    $r = Invoke-DevDetect -WorkDir $wh -ScriptArgs @('--help')
    Assert-Eq       '--help exits 0' 0 $r.Code
    Assert-Contains '--help lists exit codes' $r.Out 'INIT'
    if (Test-Path (Join-Path $wh 'logs')) {
        Fail-Assert '--help did not run a pass (no logs dir)'
    } else {
        Pass-Assert '--help did not run a pass (no logs dir)'
    }

    # -----------------------------------------------------------------------
    Write-Section 'unrecognized argument -> usage error, exit 64, no pass'
    $wu = New-WorkDir
    $r = Invoke-DevDetect -WorkDir $wu -ScriptArgs @('10')
    Assert-Eq       'bad arg exits 64' 64 $r.Code
    Assert-Contains 'bad arg names the offending token' $r.Out '10'
    if (Test-Path (Join-Path $wu 'logs')) {
        Fail-Assert 'bad arg did not run a pass (no logs dir)'
    } else {
        Pass-Assert 'bad arg did not run a pass (no logs dir)'
    }

    # -----------------------------------------------------------------------
    Write-Section 'first run (clean DUT) -> INIT, exit 3'
    $seq = New-WorkDir
    $r = Invoke-DevDetect -WorkDir $seq
    Assert-Eq 'first standalone run exit code' 3 $r.Code
    $sc = Get-LatestSidecar -WorkDir $seq
    if ($null -eq $sc) {
        Fail-Assert 'JSON sidecar written on first run'
    } else {
        Assert-Eq 'sidecar result == INIT' 'INIT' $sc.result
        Assert-Eq 'sidecar mode == standalone' 'standalone' $sc.mode
        Assert-Eq 'sidecar m is null' '' ([string]$sc.m)
        Assert-Eq 'sidecar schema_version == 2.0' '2.0' ([string]$sc.schema_version)
        $compCount = @($sc.components.PSObject.Properties).Count
        Assert-Eq 'sidecar reports 5 components' 5 $compCount
        # Layer 2: each component is now a { result, current, golden } object.
        $cpu = $sc.components.cpu_model
        if ($null -eq $cpu) {
            Fail-Assert 'cpu_model component present'
        } else {
            Assert-Eq 'cpu_model.result == INIT' 'INIT' $cpu.result
            if ($cpu.PSObject.Properties.Name -contains 'current') {
                Pass-Assert 'cpu_model carries a current scalar'
            } else {
                Fail-Assert 'cpu_model carries a current scalar'
            }
            # On INIT nothing was compared, so golden is null.
            Assert-Eq 'cpu_model.golden is null on INIT' '' ([string]$cpu.golden)
        }
    }

    # -----------------------------------------------------------------------
    Write-Section 'second run, unchanged hardware -> Pass, exit 0'
    $r = Invoke-DevDetect -WorkDir $seq
    Assert-Eq 'second standalone run exit code' 0 $r.Code
    $sc = Get-LatestSidecar -WorkDir $seq
    if ($null -eq $sc) { Fail-Assert 'JSON sidecar written on second run' }
    else {
        Assert-Eq 'sidecar result == Pass' 'Pass' $sc.result
        # On a Pass, the per-component golden is populated and equals current.
        $cpu = $sc.components.cpu_model
        if ($null -eq $cpu) {
            Fail-Assert 'cpu_model component present on Pass'
        } else {
            Assert-Eq 'cpu_model.result == Pass' 'Pass' $cpu.result
            Assert-Eq 'cpu_model.golden equals current on Pass' ([string]$cpu.current) ([string]$cpu.golden)
        }
    }

    # -----------------------------------------------------------------------
    Write-Section 'golden mismatch -> Fail, exit 1'
    $goldenCpu = Join-Path $seq 'logs\golden_cpu.log'
    if (-not (Test-Path $goldenCpu)) {
        Fail-Assert 'locate persisted CPU golden to corrupt'
    } else {
        Add-Content -Path $goldenCpu -Value 'INJECTED_MISMATCH_LINE'
        $r = Invoke-DevDetect -WorkDir $seq
        Assert-Eq 'post-corruption run exit code' 1 $r.Code
        $sc = Get-LatestSidecar -WorkDir $seq
        if ($null -eq $sc) { Fail-Assert 'JSON sidecar written on Fail run' }
        else {
            Assert-Eq 'sidecar result == Fail' 'Fail' $sc.result
            # The corruption was injected into the CPU golden, so that
            # component specifically must report Fail.
            $cpu = $sc.components.cpu_model
            if ($null -eq $cpu) { Fail-Assert 'cpu_model component present on Fail' }
            else { Assert-Eq 'cpu_model.result == Fail' 'Fail' $cpu.result }
        }
    }

    # -----------------------------------------------------------------------
    Write-Section 'snapshot mode records mode=snapshot, no reboot/scheduled task'
    $snap = New-WorkDir
    $before = @(Get-ScheduledTask -ErrorAction SilentlyContinue).Count
    $r = Invoke-DevDetect -WorkDir $snap -ScriptArgs @('-SnapshotOnly')
    # First run on a clean DUT is INIT/3 regardless of mode.
    Assert-Eq 'snapshot first run exit code (INIT)' 3 $r.Code
    $sc = Get-LatestSidecar -WorkDir $snap
    if ($null -eq $sc) { Fail-Assert 'JSON sidecar written in snapshot mode' }
    else { Assert-Eq 'sidecar mode == snapshot' 'snapshot' $sc.mode }
    $after = @(Get-ScheduledTask -ErrorAction SilentlyContinue).Count
    Assert-Eq 'no scheduled task created by dev_detect.ps1' $before $after
}
finally {
    foreach ($d in $script:_tempdirs) {
        if (Test-Path $d) { Remove-Item -Path $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Write-Host ''
Write-Host '============================================='
Write-Host ("Results: {0} passed, {1} failed" -f $script:_pass, $script:_fail)
Write-Host '============================================='
if ($script:_fail -gt 0) { exit 1 } else { exit 0 }
