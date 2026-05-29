<#
.SYNOPSIS
  Hardware baseline & verification tool (CPU, Memory, USB, NIC, Storage)
  with best-effort PCIe/USB/SATA link info.  PowerShell 5.1 compatible.

.DESCRIPTION
  - Ensures a "logs" folder beside this script.
  - Loads config.ps1 if present beside this script (for $_date2 / $_newcount).
  - Runs five hardware checks and compares against golden reference files.
  - First run initialises each golden file from the current machine values.
  - Subsequent runs compare current values to goldens; deviations = FAIL.
  - Per-run log : logs\<count>_<date2>_<PASS|FAIL>.log
  - Summary log : logs\summary.log

  Designed to run at startup via Task Scheduler (as SYSTEM, no user logon
  needed).  Register via: setup_dut.ps1 -DevDetectScript <path>

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\dev_detect1.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Version & shared library ──────────────────────────────────────────────────

$_script_ver                = '00.00.02'
$_requires_function_ps1_api = '00.00.01'

$_script_root = Split-Path -Parent $MyInvocation.MyCommand.Definition

$_fn = Join-Path $_script_root 'function.ps1'
if (-not (Test-Path $_fn)) {
    Write-Error "function.ps1 not found at $_fn — cannot continue"
    exit 1
}
. $_fn
if ($script:_function_ps1_api -lt $_requires_function_ps1_api) {
    Write-Error "function.ps1 API '$($script:_function_ps1_api)' is too old; need '$_requires_function_ps1_api'"
    exit 1
}

# ── Paths (required by group-4 functions in function.ps1) ─────────────────────

$_log_path     = Join-Path $_script_root 'logs'
$_summary_file = Join-Path $_log_path 'summary.log'
$_counter_file = Join-Path $_log_path 'counter.log'

if (-not (Test-Path $_log_path)) {
    New-Item -Path $_log_path -ItemType Directory | Out-Null
}

# Optional: load config.ps1 beside this script (provides $_date2 / $_newcount)
$_cfg = Resolve-FirstExisting -Paths @( (Join-Path $_script_root 'config.ps1') )
if ($_cfg) { . $_cfg }

# ── CPU check ─────────────────────────────────────────────────────────────────

function Get-Cpu-Text {
    (Get-CimInstance Win32_Processor | Select-Object Name | Out-String).TrimEnd()
}
function Get-Cpu-Scalar {
    $names = Get-CimInstance Win32_Processor | Select-Object -ExpandProperty Name
    $arr = @()
    foreach ($n in $names) { if ($null -ne $n -and $n.Trim() -ne '') { $arr += $n.Trim() } }
    if ($arr.Count -eq 0) { return '' }
    return ($arr -join '; ')
}
function Invoke-CpuCheck {
    $_current_text   = Get-Cpu-Text
    $_current_scalar = Get-Cpu-Scalar
    $_golden_scalar  = Ensure-Golden -GoldenFileName 'golden_cpu.log' -CurrentScalar $_current_scalar
    [pscustomobject]@{
        name           = 'cpu_model'
        result_tag     = if ($_current_scalar -eq $_golden_scalar) { 'PASS' } else { 'FAIL' }
        content_text   = $_current_text
        golden_scalar  = $_golden_scalar
        current_scalar = $_current_scalar
    }
}

# ── Memory check ──────────────────────────────────────────────────────────────

function Get-Memory-Text {
    $totalBytes = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
    $totalGB    = [math]::Round($totalBytes / 1GB)
    $perDimms   = Get-CimInstance Win32_PhysicalMemory |
                    Select-Object Manufacturer,
                        @{Name='CapacityGB'; Expression={[math]::Round($_.Capacity/1GB)}},
                        Speed
    return ("TotalPhysicalMemoryGB: {0}`r`n{1}" -f $totalGB, ($perDimms | Format-Table -AutoSize | Out-String).TrimEnd())
}
function Get-Memory-Scalar {
    $totalBytes = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
    if ($null -eq $totalBytes) { return '' }
    return ([math]::Round($totalBytes / 1GB)).ToString()
}
function Invoke-MemoryCheck {
    $_current_text   = Get-Memory-Text
    $_current_scalar = Get-Memory-Scalar
    $_golden_scalar  = Ensure-Golden -GoldenFileName 'golden_mem_total.log' -CurrentScalar $_current_scalar
    [pscustomobject]@{
        name           = 'memory_total_gb'
        result_tag     = if ($_current_scalar -eq $_golden_scalar) { 'PASS' } else { 'FAIL' }
        content_text   = $_current_text
        golden_scalar  = $_golden_scalar
        current_scalar = $_current_scalar
    }
}

# ── USB check (PassMark loopback plug count + version hint) ───────────────────

$_usb_target_name = 'PassMark USB3.0 Loopback plug'

function Get-UsbMatches {
    Get-PnpDevice -PresentOnly | Where-Object { $_.FriendlyName -eq $_usb_target_name }
}
function Get-Usb-Text {
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
function Get-Usb-Scalar {
    (@( Get-UsbMatches )).Count.ToString()
}
function Invoke-UsbCheck {
    $_current_text   = Get-Usb-Text
    $_current_scalar = Get-Usb-Scalar
    $_golden_scalar  = Ensure-Golden -GoldenFileName 'golden_usb_passmark_count.log' -CurrentScalar $_current_scalar
    [pscustomobject]@{
        name           = 'usb_passmark_count'
        result_tag     = if ($_current_scalar -eq $_golden_scalar) { 'PASS' } else { 'FAIL' }
        content_text   = $_current_text
        golden_scalar  = $_golden_scalar
        current_scalar = $_current_scalar
    }
}

# ── NIC check (model counts + best-effort PCIe link info) ─────────────────────

function Get-Nic-Objects {
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
function Get-Nic-Text {
    $objs = @( Get-Nic-Objects )
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
            PcieGen              = if ($link) { $link.Gen }      else { 'Unknown' }
            PcieWidth            = if ($link) { $link.Width }    else { 'Unknown' }
            PcieSpeed            = if ($link) { $link.SpeedGTs } else { 'Unknown' }
            PcieApproxGBs        = if ($link) { $link.ApproxGBs } else { 'Unknown' }
        }
    }
    $detail     = ($rows | Format-Table -AutoSize | Out-String).TrimEnd()
    $counts     = ($rows | Group-Object InterfaceDescription | Sort-Object Name |
                    ForEach-Object { [pscustomobject]@{ Model=$_.Name; Count=$_.Count } } |
                    Format-Table -AutoSize | Out-String).TrimEnd()
    "NICs (all physical):`r`n{0}`r`n`r`nCounts by model:`r`n{1}" -f $detail, $counts
}
function Get-Nic-Scalar {
    $objs   = @( Get-Nic-Objects )
    $pairs  = @()
    $groups = $objs | Group-Object InterfaceDescription
    foreach ($g in $groups) {
        $name   = if ($null -ne $g.Name) { $g.Name.Trim() } else { 'UnknownModel' }
        $pairs += '{0}|{1}' -f $name, $g.Count
    }
    ($pairs | Sort-Object) -join ' ; '
}
function Invoke-NicCheck {
    $_current_text   = Get-Nic-Text
    $_current_scalar = Get-Nic-Scalar
    $_golden_scalar  = Ensure-Golden -GoldenFileName 'golden_nic_model_count.log' -CurrentScalar $_current_scalar
    [pscustomobject]@{
        name           = 'nic_model_counts'
        result_tag     = if ($_current_scalar -eq $_golden_scalar) { 'PASS' } else { 'FAIL' }
        content_text   = $_current_text
        golden_scalar  = $_golden_scalar
        current_scalar = $_current_scalar
    }
}

# ── Storage check (model+bus counts + best-effort link info) ──────────────────

function Get-Storage-Objects {
    try { return Get-PhysicalDisk } catch { return Get-CimInstance Win32_DiskDrive }
}
function Get-Storage-Text {
    $objs = @( Get-Storage-Objects )
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
            elseif ($bus -match 'SATA|ATA')      { $sataRate = TryGet-SataLinkRate -InstanceId $iid }
        }
        [pscustomobject]@{
            Model         = $model; Bus = $bus; SizeGB = $szGB
            PCIeGen       = if ($pcieInfo) { $pcieInfo.Gen }      else { $null }
            PCIeWidth     = if ($pcieInfo) { $pcieInfo.Width }    else { $null }
            PCIeSpeed     = if ($pcieInfo) { $pcieInfo.SpeedGTs } else { $null }
            PCIeApproxGBs = if ($pcieInfo) { $pcieInfo.ApproxGBs } else { $null }
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
function Get-Storage-Scalar {
    $objs  = @( Get-Storage-Objects )
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
    $_current_text   = Get-Storage-Text
    $_current_scalar = Get-Storage-Scalar
    $_golden_scalar  = Ensure-Golden -GoldenFileName 'golden_storage_model_bus_count.log' -CurrentScalar $_current_scalar
    [pscustomobject]@{
        name           = 'storage_model_bus_counts'
        result_tag     = if ($_current_scalar -eq $_golden_scalar) { 'PASS' } else { 'FAIL' }
        content_text   = $_current_text
        golden_scalar  = $_golden_scalar
        current_scalar = $_current_scalar
    }
}

# ── Main ──────────────────────────────────────────────────────────────────────

$_date2 = Get-Date2
$_count = Get-NextCount

$_results  = @()
$_results += Invoke-CpuCheck
$_results += Invoke-MemoryCheck
$_results += Invoke-UsbCheck
$_results += Invoke-NicCheck
$_results += Invoke-StorageCheck

$_overall_tag  = if (@($_results | Where-Object { $_.result_tag -ne 'PASS' }).Count -eq 0) { 'PASS' } else { 'FAIL' }

$_per_run_path = Write-CombinedPerRunLog -Count $_count -Date2 $_date2 -OverallTag $_overall_tag -Results $_results
Append-CombinedSummary                  -Count $_count -Date2 $_date2 -OverallTag $_overall_tag -Results $_results

Write-Host ("Overall    : {0}" -f $_overall_tag)
Write-Host ("Per-run log: {0}" -f $_per_run_path)
Write-Host ("Summary log: {0}" -f $_summary_file)
