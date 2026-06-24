<#
.SYNOPSIS
  Hardware baseline & verification tool (CPU, Memory, USB, NIC, Storage)
  with best-effort PCIe/USB/SATA link info.  PowerShell 5.1 compatible.

.DESCRIPTION
  - Ensures a "logs" folder beside this script.
  - Loads the shared settings file config.ps1 if present beside this script (SET001).
  - Runs five hardware checks and compares against golden reference files.
  - First run initialises each golden file from the current machine values.
  - Subsequent runs compare current values to goldens; deviations = FAIL.
  - Per-run log : logs\COUNT_DATE_PASS-or-FAIL.log
  - Summary log : logs\summary.log

  Designed to run at startup via Task Scheduler (as SYSTEM, no user logon
  needed).  Register via: setup_dut.ps1 -DevDetectScript PATH_TO_SCRIPT

  DET013 run modes:
    (default)        Standalone. Unchanged: re-invoked at every boot by the
                      Task Scheduler entry registered via setup_dut.ps1; this
                      script itself never reboots/powers off (it never has).
    -SnapshotOnly     Same single pass; documents that an external
                      orchestrator (e.g. power_cycle.py) owns the loop and
                      power-cycling for this run. dev_detect.ps1 does not
                      install or modify the Task Scheduler entry either way
                      -- that remains setup_dut.ps1's job.

  Every pass exits with a DET013-standard code and writes a JSON sidecar
  next to its per-run .log file; see docs/dev_detect.md.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\dev_detect.ps1

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\dev_detect.ps1 -SnapshotOnly
#>

param(
    [switch]$SnapshotOnly,
    [Alias('h')][switch]$Help
)

# Accept Unix-style double-dash aliases and HARD-ERROR on anything else.
# PowerShell binds -Help / -SnapshotOnly natively; any argument it could not
# bind (e.g. --help, --snapshot-only, a positional count like "10", a typo)
# lands in $args. The original script left $args unread, so unknown arguments
# were silently swallowed and a normal detection pass ran anyway -- bumping the
# counter and writing a misleading log. We now translate the known aliases and
# reject everything else before any side effect occurs.
$_show_help = [bool]$Help
foreach ($_a in $args) {
    switch -Regex ("$_a") {
        '^(--help|-\?|/\?|/h|/help)$' { $_show_help = $true }
        '^--snapshot-only$'           { $SnapshotOnly = $true }
        default {
            Write-Host "dev_detect.ps1: unrecognized argument '$_a'" -ForegroundColor Red
            Write-Host "Run 'dev_detect.ps1 -Help' (or --help) for usage." -ForegroundColor Red
            exit 64   # EX_USAGE; deliberately NOT a DET013 verdict (0/1/2/3)
        }
    }
}

if ($_show_help) {
    @'
Usage: dev_detect.ps1 [-SnapshotOnly|--snapshot-only] [-Help|-h|--help]

Run modes:
  (no flag)       Standalone mode (default). Re-invoked at every boot by the
                  Task Scheduler entry (registered via setup_dut.ps1). This
                  script performs one pass and exits either way; it has no
                  self-triggered reboot/poweroff to suppress.
  -SnapshotOnly   Documents that an external orchestrator (e.g.
  --snapshot-only power_cycle.py) owns the loop/power-cycling for this run.
                  Behaves the same as default mode (see above) -- the flag
                  exists for parity with dev_detect.sh and so the JSON
                  sidecar can record which mode produced a given pass.

Other options:
  -Help, -h       Show this help and exit. --help is also accepted.

Note: this PowerShell port performs exactly ONE pass per invocation; the
repeat/reboot loop is owned by Task Scheduler (standalone) or an external
orchestrator (snapshot). It does NOT accept a pass-count argument the way
dev_detect.sh does -- see docs/dev_detect.md.

Exit codes:
  0  Pass   - every check matches its existing golden reference
  1  Fail   - at least one check deviates from its golden reference
  2  Error  - a check could not run
  3  INIT   - at least one golden did not exist yet and was just created
             (not a verified pass), and no check failed
  64 Usage  - unrecognized command-line argument (no pass run)

Each pass also writes a JSON sidecar next to its per-run .log file; see
docs/dev_detect.md for the schema.
'@ | Write-Host
    exit 0
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -- Version & shared library --------------------------------------------------

$_script_ver                = '00.00.05'
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

# -- Paths (required by group-4 functions in function.ps1) ---------------------

$_log_path     = Join-Path $_script_root 'logs'
$_summary_file = Join-Path $_log_path 'summary.log'
$_counter_file = Join-Path $_log_path 'counter.log'

if (-not (Test-Path $_log_path)) {
    New-Item -Path $_log_path -ItemType Directory | Out-Null
}

# Optional: load the shared settings file (config.ps1, SET001) if present.
$_cfg = Resolve-FirstExisting -Paths @( (Join-Path $_script_root 'config.ps1') )
if ($_cfg) { . $_cfg }

# DET013: a freshly-created golden never verified anything -- report INIT,
# not PASS, so the orchestrator can tell "just baselined" from "checked OK".
function Get-DevDetectResultTag {
    param([string]$CurrentScalar, [string]$GoldenScalar)
    if ($script:_golden_was_init) { return 'INIT' }
    if ($CurrentScalar -eq $GoldenScalar) { return 'Pass' }
    return 'Fail'
}

# -- CPU check -----------------------------------------------------------------

function Get-CpuText {
    (Get-CimInstance Win32_Processor | Select-Object Name | Out-String).TrimEnd()
}
function Get-CpuScalar {
    $names = Get-CimInstance Win32_Processor | Select-Object -ExpandProperty Name
    $arr = @()
    foreach ($n in $names) { if ($null -ne $n -and $n.Trim() -ne '') { $arr += $n.Trim() } }
    if ($arr.Count -eq 0) { return '' }
    return ($arr -join '; ')
}
function Invoke-CpuCheck {
    $currentText   = Get-CpuText
    $currentScalar = Get-CpuScalar
    $goldenScalar  = Initialize-Golden -GoldenFileName 'golden_cpu.log' -CurrentScalar $currentScalar
    [pscustomobject]@{
        name           = 'cpu_model'
        result_tag     = Get-DevDetectResultTag -CurrentScalar $currentScalar -GoldenScalar $goldenScalar
        content_text   = $currentText
        golden_scalar  = $goldenScalar
        current_scalar = $currentScalar
    }
}

# -- Memory check --------------------------------------------------------------

function Get-MemoryText {
    $totalBytes = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
    $totalGB    = [math]::Round($totalBytes / 1GB)
    $perDimms   = Get-CimInstance Win32_PhysicalMemory |
                    Select-Object Manufacturer,
                        @{Name='PartNumber'; Expression={ if ($_.PartNumber) { $_.PartNumber.ToString().Trim() } else { 'Unknown' } }},
                        @{Name='CapacityGB'; Expression={[math]::Round($_.Capacity/1GB)}},
                        Speed
    return ("TotalPhysicalMemoryGB: {0}`r`n{1}" -f $totalGB, ($perDimms | Format-Table -AutoSize | Out-String).TrimEnd())
}
function Get-MemoryScalar {
    $totalBytes = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
    if ($null -eq $totalBytes) { return '' }
    return ([math]::Round($totalBytes / 1GB)).ToString()
}
function Invoke-MemoryCheck {
    $currentText   = Get-MemoryText
    $currentScalar = Get-MemoryScalar
    $goldenScalar  = Initialize-Golden -GoldenFileName 'golden_mem_total.log' -CurrentScalar $currentScalar
    [pscustomobject]@{
        name           = 'memory_total_gb'
        result_tag     = Get-DevDetectResultTag -CurrentScalar $currentScalar -GoldenScalar $goldenScalar
        content_text   = $currentText
        golden_scalar  = $goldenScalar
        current_scalar = $currentScalar
    }
}

# -- USB check (PassMark loopback plug count + version hint) -------------------

$_usb_target_name = 'PassMark USB3.0 Loopback plug'

function Get-UsbMatches {
    Get-PnpDevice -PresentOnly | Where-Object { $_.FriendlyName -eq $_usb_target_name }
}
function Get-UsbText {
    $devs  = @( Get-UsbMatches )
    $rows  = foreach ($m in $devs) {
        [pscustomobject]@{
            Status       = $m.Status
            Class        = $m.Class
            FriendlyName = $m.FriendlyName
            InstanceId   = $m.InstanceId
            UsbVersion   = (Get-UsbVersionHint -InstanceId $m.InstanceId)
        }
    }
    "Target: {0}`r`nCount: {1}`r`n{2}" -f $_usb_target_name, $devs.Count, ($rows | Format-Table -AutoSize | Out-String).TrimEnd()
}
function Get-UsbScalar {
    (@( Get-UsbMatches )).Count.ToString()
}
function Invoke-UsbCheck {
    $currentText   = Get-UsbText
    $currentScalar = Get-UsbScalar
    $goldenScalar  = Initialize-Golden -GoldenFileName 'golden_usb_passmark_count.log' -CurrentScalar $currentScalar
    [pscustomobject]@{
        name           = 'usb_passmark_count'
        result_tag     = Get-DevDetectResultTag -CurrentScalar $currentScalar -GoldenScalar $goldenScalar
        content_text   = $currentText
        golden_scalar  = $goldenScalar
        current_scalar = $currentScalar
    }
}

# -- NIC check (model counts + best-effort PCIe link info) ---------------------

function Get-NicObjects {
    try {
        return Get-NetAdapter | Where-Object { $_.HardwareInterface -eq $true }
    } catch {
        $all  = Get-CimInstance Win32_NetworkAdapter
        $cand = @()
        foreach ($a in $all) {
            if ($a.PSObject.Properties.Name -contains 'PhysicalAdapter') {
                if ($a.PhysicalAdapter) { $cand += $a }
            } else {
                if ($a.PNPDeviceID -and ($a.Name -notmatch 'Bluetooth|Virtual|Hyper-V|VMware')) { $cand += $a }
            }
        }
        return $cand
    }
}
function Get-NicText {
    $objs = @( Get-NicObjects )
    $rows = foreach ($o in $objs) {
        $desc = if ($o.PSObject.Properties.Name -contains 'InterfaceDescription') { $o.InterfaceDescription }
                elseif ($o.PSObject.Properties.Name -contains 'Name') { $o.Name }
                else { $null }

        $statusVal = $null
        if ($o.PSObject.Properties.Name -contains 'Status' -and $null -ne $o.Status) {
            $statusVal = $o.Status
        } elseif ($o.PSObject.Properties.Name -contains 'NetConnectionStatus' -and $null -ne $o.NetConnectionStatus) {
            $statusVal = $o.NetConnectionStatus
        }

        $iid = $null
        if ($o.PSObject.Properties.Name -contains 'PnPDeviceID') { $iid = $o.PnPDeviceID }
        if (-not $iid) {
            $wa = Get-CimInstance Win32_NetworkAdapter |
                    Where-Object { $_.Name -eq $o.Name -or $_.NetConnectionID -eq $o.Name } |
                    Select-Object -First 1
            if ($wa) { $iid = $wa.PNPDeviceID }
        }
        $link = if ($iid) { Get-PcieLinkInfo -InstanceIdOrChild $iid } else { $null }

        $speedGbps = $null
        if ($o.PSObject.Properties.Name -contains 'LinkSpeed' -and $o.LinkSpeed) {
            $speedGbps = Convert-LinkSpeedToGb -Value $o.LinkSpeed
        } elseif ($o.PSObject.Properties.Name -contains 'Speed' -and $o.Speed) {
            $speedGbps = Convert-LinkSpeedToGb -Value $o.Speed
        }

        [pscustomobject]@{
            Name                 = $o.Name
            InterfaceDescription = $desc
            Status               = $statusVal
            SpeedGbps            = $speedGbps
            PcieGenSpeed         = if ($link) { $link.GenSpeed }       else { 'Unknown' }
            PcieWidth            = if ($link) { $link.Width }          else { 'Unknown' }
            PcieTheoreticalGBs   = if ($link) { $link.TheoreticalGBs } else { 'Unknown' }
        }
    }
    $detail     = ($rows | Format-Table -AutoSize | Out-String).TrimEnd()
    $counts     = ($rows | Group-Object InterfaceDescription | Sort-Object Name |
                    ForEach-Object { [pscustomobject]@{ Model=$_.Name; Count=$_.Count } } |
                    Format-Table -AutoSize | Out-String).TrimEnd()
    "NICs (all physical):`r`n{0}`r`n`r`nCounts by model:`r`n{1}" -f $detail, $counts
}
function Get-NicScalar {
    $objs   = @( Get-NicObjects )
    $pairs  = @()
    $groups = $objs | Group-Object InterfaceDescription
    foreach ($g in $groups) {
        $name   = if ($null -ne $g.Name) { $g.Name.Trim() } else { 'UnknownModel' }
        $pairs += '{0}|{1}' -f $name, $g.Count
    }
    ($pairs | Sort-Object) -join ' ; '
}
function Invoke-NicCheck {
    $currentText   = Get-NicText
    $currentScalar = Get-NicScalar
    $goldenScalar  = Initialize-Golden -GoldenFileName 'golden_nic_model_count.log' -CurrentScalar $currentScalar
    [pscustomobject]@{
        name           = 'nic_model_counts'
        result_tag     = Get-DevDetectResultTag -CurrentScalar $currentScalar -GoldenScalar $goldenScalar
        content_text   = $currentText
        golden_scalar  = $goldenScalar
        current_scalar = $currentScalar
    }
}

# -- Storage check (model+bus counts + best-effort link info) ------------------

function Get-StorageObjects {
    try { return Get-PhysicalDisk } catch { return Get-CimInstance Win32_DiskDrive }
}
function Get-StorageText {
    $objs = @( Get-StorageObjects )
    $rows = foreach ($d in $objs) {
        $model = if ($d.PSObject.Properties.Name -contains 'FriendlyName' -and $d.FriendlyName) { $d.FriendlyName.ToString().Trim() }
                 elseif ($d.PSObject.Properties.Name -contains 'Model' -and $d.Model)           { $d.Model.ToString().Trim() }
                 else { 'UnknownModel' }
        $bus   = if ($d.PSObject.Properties.Name -contains 'BusType' -and $d.BusType)           { $d.BusType.ToString().Trim() }
                 elseif ($d.PSObject.Properties.Name -contains 'InterfaceType' -and $d.InterfaceType) { $d.InterfaceType.ToString().Trim() }
                 else { 'UnknownBus' }
        $szGB  = if ($d.PSObject.Properties.Name -contains 'Size' -and $d.Size) { [math]::Round($d.Size/1GB) } else { $null }

        $iid = $null
        $wdd = Get-CimInstance Win32_DiskDrive |
                 Where-Object { $_.Model -eq $model -and ([math]::Round($_.Size/1GB) -eq $szGB) } |
                 Select-Object -First 1
        if ($wdd) { $iid = $wdd.PNPDeviceID }

        $pcieInfo = $null; $usbHint = $null; $sataRate = $null
        if ($iid) {
            if    ($bus -match 'NVMe|RAID|PCI') { $pcieInfo = Get-PcieLinkInfo -InstanceIdOrChild $iid }
            elseif ($bus -match 'USB')           { $usbHint  = Get-UsbVersionHint -InstanceId $iid }
            elseif ($bus -match 'SATA|ATA')      { $sataRate = Get-SataLinkRate -InstanceId $iid }
        }
        [pscustomobject]@{
            Model         = $model; Bus = $bus; SizeGB = $szGB
            PCIeGenSpeed       = if ($pcieInfo) { $pcieInfo.GenSpeed }       else { $null }
            PCIeWidth          = if ($pcieInfo) { $pcieInfo.Width }          else { $null }
            PCIeTheoreticalGBs = if ($pcieInfo) { $pcieInfo.TheoreticalGBs } else { $null }
            UsbVersion    = $usbHint
            SataLink      = $sataRate
        }
    }
    $detail = ($rows | Format-Table -AutoSize | Out-String).TrimEnd()
    $counts = ($rows | ForEach-Object { '{0}|{1}' -f $_.Model, $_.Bus } |
                Group-Object | Sort-Object Name |
                ForEach-Object { $tok = $_.Name.Split('|',2); [pscustomobject]@{ Model=$tok[0]; Bus=$tok[1]; Count=$_.Count } } |
                Format-Table -AutoSize | Out-String).TrimEnd()
    "Storage devices:`r`n{0}`r`n`r`nCounts by model+bus:`r`n{1}" -f $detail, $counts
}
function Get-StorageScalar {
    $objs  = @( Get-StorageObjects )
    $pairs = @()
    foreach ($d in $objs) {
        $model = if ($d.PSObject.Properties.Name -contains 'FriendlyName' -and $d.FriendlyName) { $d.FriendlyName.ToString().Trim() }
                 elseif ($d.PSObject.Properties.Name -contains 'Model' -and $d.Model)           { $d.Model.ToString().Trim() }
                 else { 'UnknownModel' }
        $bus   = if ($d.PSObject.Properties.Name -contains 'BusType' -and $d.BusType)           { $d.BusType.ToString().Trim() }
                 elseif ($d.PSObject.Properties.Name -contains 'InterfaceType' -and $d.InterfaceType) { $d.InterfaceType.ToString().Trim() }
                 else { 'UnknownBus' }
        $pairs += '{0}|{1}' -f $model, $bus
    }
    $groups = $pairs | Group-Object
    ($groups | ForEach-Object { '{0}|{1}' -f $_.Name, $_.Count } | Sort-Object) -join ' ; '
}
function Invoke-StorageCheck {
    $currentText   = Get-StorageText
    $currentScalar = Get-StorageScalar
    $goldenScalar  = Initialize-Golden -GoldenFileName 'golden_storage_model_bus_count.log' -CurrentScalar $currentScalar
    [pscustomobject]@{
        name           = 'storage_model_bus_counts'
        result_tag     = Get-DevDetectResultTag -CurrentScalar $currentScalar -GoldenScalar $goldenScalar
        content_text   = $currentText
        golden_scalar  = $goldenScalar
        current_scalar = $currentScalar
    }
}

# -- Main ----------------------------------------------------------------------

$_date2 = Get-Date2
$_count = Get-NextCount

$_results  = @()
$_results += Invoke-CpuCheck
$_results += Invoke-MemoryCheck
$_results += Invoke-UsbCheck
$_results += Invoke-NicCheck
$_results += Invoke-StorageCheck

# DET013: precedence mirrors dev_detect.sh -- Fail beats INIT beats Pass.
# (Error is reserved for a check that threw; CIM/exception failures above
# already propagate via $ErrorActionPreference = 'Stop' rather than landing
# here as a result_tag, so it is not assigned below.)
if     (@($_results | Where-Object { $_.result_tag -eq 'Fail' }).Count -gt 0) { $_overall_tag = 'Fail' }
elseif (@($_results | Where-Object { $_.result_tag -eq 'INIT' }).Count -gt 0) { $_overall_tag = 'INIT' }
else                                                                          { $_overall_tag = 'Pass' }

$_exit_code = switch ($_overall_tag) {
    'Pass' { 0 }
    'Fail' { 1 }
    'INIT' { 3 }
    default { 2 }
}

$_per_run_path = Write-CombinedPerRunLog -Count $_count -Date2 $_date2 -OverallTag $_overall_tag -Results $_results
Add-CombinedSummary                  -Count $_count -Date2 $_date2 -OverallTag $_overall_tag -Results $_results

# DET013 / contract-alignment-plan Layer 2: JSON sidecar, additive to the
# existing per-run .log file. Each component now carries the full
# { result, current, golden } triple instead of a bare result tag, so the
# orchestrator gets per-component comparison without parsing any text. On an
# INIT pass no golden existed yet, so golden is emitted as null (the scalar
# we hold is the just-baselined value, not something we compared against).
$_components = [ordered]@{}
foreach ($r in $_results) {
    $_components[$r.name] = [ordered]@{
        result  = $r.result_tag
        current = $r.current_scalar
        golden  = $(if ($r.result_tag -eq 'INIT') { $null } else { $r.golden_scalar })
    }
}
$_sidecar_path = Join-Path $_log_path ('{0}_{1}_{2}.json' -f $_count, $_date2, $_overall_tag)
[ordered]@{
    schema_version = '2.0'
    session_id     = $_date2
    k              = $_count
    m              = $null
    result         = $_overall_tag
    timestamp      = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    log_path       = $_per_run_path
    mode           = $(if ($SnapshotOnly) { 'snapshot' } else { 'standalone' })
    components     = $_components
} | ConvertTo-Json -Depth 5 | Set-Content -Path $_sidecar_path -Encoding UTF8

Write-Host ("Overall    : {0}" -f $_overall_tag)
Write-Host ("Per-run log: {0}" -f $_per_run_path)
Write-Host ("Sidecar    : {0}" -f $_sidecar_path)
Write-Host ("Summary log: {0}" -f $_summary_file)

exit $_exit_code
