<#
.SYNOPSIS
  Hardware baseline & verification tool (CPU, Memory, USB, NIC, Storage)
  with best-effort PCIe/USB/SATA link info.  PowerShell 5.1 compatible.

.DESCRIPTION
  - Ensures a "logs" folder beside this script.
  - Loads config.ps1 / function.ps1 if present beside this script
    to reuse ${_date2} and ${_newcount}.
  - Runs multiple checks (modules):
      * CPU model
      * Memory total capacity (GB, rounded)
      * USB PassMark Loopback plug count
      * NIC model counts (all physical up/down) + best-effort PCIe link info
      * Storage model+bus counts + best-effort PCIe/SATA link info
  - First run initializes each golden file with the current machine values.
  - Subsequent runs compare current values to goldens.
  - Per-run combined log       : <count>_<date2>_<PASS|FAIL>.log
  - Global appended summary log: logs\summary.log

  Designed to run at startup via Task Scheduler (as SYSTEM, no user logon
  needed).  Register via setup_dut.ps1 -DevDetectScript <path>.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\dev_detect1.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Paths & config loading ────────────────────────────────────────────────────

$_script_root  = Split-Path -Parent $MyInvocation.MyCommand.Definition
$_log_path     = Join-Path $_script_root 'logs'
$_summary_file = Join-Path $_log_path 'summary.log'
$_counter_file = Join-Path $_log_path 'counter.log'

# Look for config.ps1 / function.ps1 beside this script only
$_config_candidates   = @( (Join-Path $_script_root 'config.ps1') )
$_function_candidates = @( (Join-Path $_script_root 'function.ps1') )

function Resolve-FirstExisting {
    param([Parameter(Mandatory)][string[]] $_paths)
    foreach ($_p in $_paths) { if (Test-Path $_p) { return $_p } }
    return $null
}

if (-not (Test-Path $_log_path)) {
    New-Item -Path $_log_path -ItemType Directory | Out-Null
}

$_config_path   = Resolve-FirstExisting -_paths $_config_candidates
$_function_path = Resolve-FirstExisting -_paths $_function_candidates
if ($_config_path)   { . $_config_path }
if ($_function_path) { . $_function_path }

# ── Common helpers ────────────────────────────────────────────────────────────

function Get-Date2 {
    if ($script:_date2 -and -not [string]::IsNullOrWhiteSpace($script:_date2)) { return $script:_date2 }
    return (Get-Date -Format 'yyyyMMddHHmmss')
}

function Get-NextCount {
    if ($script:_newcount -and ($script:_newcount -as [int] -ne $null)) {
        return [int]$script:_newcount
    }
    $count = 1
    if (Test-Path $_counter_file) {
        $raw = Get-Content $_counter_file -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($raw -match '^\d+$') { $count = [int]$raw + 1 }
    }
    $count | Set-Content -Path $_counter_file -Encoding UTF8
    return $count
}

function Ensure-Golden {
    param(
        [Parameter(Mandatory)][string] $_golden_file_name,
        [Parameter(Mandatory)][string] $_current_scalar
    )
    $_golden_path = Join-Path $_log_path $_golden_file_name
    $_need_init = $true
    if (Test-Path $_golden_path) {
        $_raw = Get-Content $_golden_path -Raw -ErrorAction SilentlyContinue
        if ($null -ne $_raw -and ($_raw -match '\S')) { $_need_init = $false }
    }
    if ($_need_init) {
        $_current_scalar | Set-Content -Path $_golden_path -Encoding UTF8
        Write-Host "Initialized golden: $_golden_path"
    }
    return ((Get-Content $_golden_path -Raw) -replace "`r","").Trim()
}

function Get-PnpProp {
    param(
        [Parameter(Mandatory)][string]$InstanceId,
        [Parameter(Mandatory)][string]$KeyName
    )
    try {
        $p = Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName $KeyName -ErrorAction Stop
        return $p.Data
    } catch { return $null }
}

function Get-ParentInstanceId {
    param([Parameter(Mandatory)][string]$InstanceId)
    return (Get-PnpProp -InstanceId $InstanceId -KeyName 'DEVPKEY_Device_Parent')
}

function Ascend-ToPci {
    param([Parameter(Mandatory)][string]$InstanceId)
    $iid = $InstanceId
    for ($i = 0; $i -lt 10 -and $null -ne $iid -and $iid -ne ''; $i++) {
        if ($iid -like 'PCI\*') { return $iid }
        $iid = Get-ParentInstanceId -InstanceId $iid
    }
    return $null
}

function Parse-PcieGen {
    param([double]$SpeedGTs)
    if    ($SpeedGTs -lt  3) { return 'Gen1' }
    elseif ($SpeedGTs -lt  6) { return 'Gen2' }
    elseif ($SpeedGTs -lt 12) { return 'Gen3' }
    elseif ($SpeedGTs -lt 24) { return 'Gen4' }
    elseif ($SpeedGTs -lt 40) { return 'Gen5' }
    else                      { return 'Gen-Unknown' }
}

function Approx-PcieGBsPerDir {
    param([double]$SpeedGTs, [int]$Width)
    if ($Width -lt 1) { $Width = 1 }
    $eff  = if ($SpeedGTs -lt 8.1) { 0.8 } else { (128.0/130.0) }
    $gbps = $Width * $SpeedGTs * $eff
    $gbs  = $gbps / 8.0
    return [math]::Round($gbs, 3)
}

function Get-PcieLinkInfo {
    param([Parameter(Mandatory)][string]$InstanceIdOrChild)
    $pci = if ($InstanceIdOrChild -like 'PCI\*') { $InstanceIdOrChild } else { Ascend-ToPci -InstanceId $InstanceIdOrChild }
    if (-not $pci) { return $null }

    $spd = Get-PnpProp -InstanceId $pci -KeyName 'DEVPKEY_PciDevice_CurrentLinkSpeed'
    $wid = Get-PnpProp -InstanceId $pci -KeyName 'DEVPKEY_PciDevice_CurrentLinkWidth'
    if ($null -eq $spd -and $null -eq $wid) { return $null }

    $speedGTs = 0.0
    if ($spd -is [double] -or $spd -is [single] -or $spd -is [decimal]) { $speedGTs = [double]$spd }
    elseif ($spd -is [int]) { $speedGTs = [double]$spd }
    elseif ($spd -is [string]) {
        if ($spd -match '([\d\.]+)') { $speedGTs = [double]$matches[1] } else { $speedGTs = 0.0 }
    }

    $width = 0
    if ($wid -is [int]) { $width = $wid }
    elseif ($wid -is [string] -and $wid -match '\d+') { $width = [int]$matches[0] }

    $gen = Parse-PcieGen -SpeedGTs $speedGTs
    $gbs = Approx-PcieGBsPerDir -SpeedGTs $speedGTs -Width $width

    [pscustomobject]@{
        InstanceId = $pci
        SpeedGTs   = if ($speedGTs -gt 0) { ("{0:0.0} GT/s" -f $speedGTs) } else { 'Unknown' }
        Width      = if ($width -gt 0) { "x$width" } else { 'Unknown' }
        Gen        = $gen
        ApproxGBs  = if ($gbs -gt 0) { ("~{0} GB/s (per dir)" -f $gbs) } else { 'Unknown' }
    }
}

function Get-UsbVersionHint {
    param([Parameter(Mandatory)][string]$InstanceId)
    $bcd = Get-PnpProp -InstanceId $InstanceId -KeyName 'DEVPKEY_UsbDevice_BcdUSB'
    if ($bcd) {
        try {
            $v = '{0:N2}' -f ([int]$bcd / 256.0)
            return "USB $v"
        } catch {}
    }
    $iid = $InstanceId
    for ($i = 0; $i -lt 10 -and $iid; $i++) {
        if ($iid -like 'USB\ROOT_HUB30*' -or $iid -like 'USB\ROOT_HUB3*') { return 'USB 3.x (by hub)' }
        if ($iid -like 'USB\ROOT_HUB20*') { return 'USB 2.0 (by hub)' }
        $iid = Get-ParentInstanceId -InstanceId $iid
    }
    return 'Unknown'
}

function TryGet-SataLinkRate {
    param([Parameter(Mandatory)][string]$InstanceId)
    $keys = @(
        'DEVPKEY_Storage_Port_AchievedLinkRate',
        'DEVPKEY_Storage_Port_MaxLinkRate',
        'DEVPKEY_Storage_AchievedLinkRate'
    )
    foreach ($k in $keys) {
        $v = Get-PnpProp -InstanceId $InstanceId -KeyName $k
        if ($v) {
            if ($v -is [string]) {
                if ($v -match '([\d\.]+\s*Gb/s)') { return $matches[1] }
                if ($v -match '(\d+)') {
                    $val = [int]$matches[1]
                    if ($val -in 1,3,6,12) { return "$val Gb/s" }
                }
            } elseif ($v -is [int]) {
                if ($v -in 1,3,6,12) { return "$v Gb/s" }
            }
            return "$v"
        }
    }
    return $null
}

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
    $_golden_scalar  = Ensure-Golden -_golden_file_name 'golden_cpu.log' -_current_scalar $_current_scalar
    $_is_match       = ($_current_scalar -eq $_golden_scalar)
    [pscustomobject]@{
        name           = 'cpu_model'
        result_tag     = if ($_is_match) { 'PASS' } else { 'FAIL' }
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
    $textTotal  = "TotalPhysicalMemoryGB: {0}" -f $totalGB
    $textDimms  = ($perDimms | Format-Table -AutoSize | Out-String).TrimEnd()
    return ($textTotal + "`r`n" + $textDimms)
}
function Get-Memory-Scalar {
    $totalBytes = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
    if ($null -eq $totalBytes) { return '' }
    return ([math]::Round($totalBytes / 1GB)).ToString()
}
function Invoke-MemoryCheck {
    $_current_text   = Get-Memory-Text
    $_current_scalar = Get-Memory-Scalar
    $_golden_scalar  = Ensure-Golden -_golden_file_name 'golden_mem_total.log' -_current_scalar $_current_scalar
    $_is_match       = ($_current_scalar -eq $_golden_scalar)
    [pscustomobject]@{
        name           = 'memory_total_gb'
        result_tag     = if ($_is_match) { 'PASS' } else { 'FAIL' }
        content_text   = $_current_text
        golden_scalar  = $_golden_scalar
        current_scalar = $_current_scalar
    }
}

# ── USB check (PassMark loopback plug count + version hint) ───────────────────

$_usb_target_name = 'PassMark USB3.0 Loopback plug'

function Get-UsbMatches {
    Get-PnpDevice -PresentOnly |
        Where-Object { $_.FriendlyName -eq $_usb_target_name }
}
function Get-Usb-Text {
    $devs  = @( Get-UsbMatches )
    $count = $devs.Count
    $rows  = foreach ($m in $devs) {
        $ver = Get-UsbVersionHint -InstanceId $m.InstanceId
        [pscustomobject]@{
            Status       = $m.Status
            Class        = $m.Class
            FriendlyName = $m.FriendlyName
            InstanceId   = $m.InstanceId
            UsbVersion   = $ver
        }
    }
    $table = ($rows | Format-Table -AutoSize | Out-String).TrimEnd()
    ("Target: {0}`r`nCount: {1}`r`n{2}" -f $_usb_target_name, $count, $table)
}
function Get-Usb-Scalar {
    $devs = @( Get-UsbMatches )
    $devs.Count.ToString()
}
function Invoke-UsbCheck {
    $_current_text   = Get-Usb-Text
    $_current_scalar = Get-Usb-Scalar
    $_golden_scalar  = Ensure-Golden -_golden_file_name 'golden_usb_passmark_count.log' -_current_scalar $_current_scalar
    $_is_match       = ($_current_scalar -eq $_golden_scalar)
    [pscustomobject]@{
        name           = 'usb_passmark_count'
        result_tag     = if ($_is_match) { 'PASS' } else { 'FAIL' }
        content_text   = $_current_text
        golden_scalar  = $_golden_scalar
        current_scalar = $_current_scalar
    }
}

# ── NIC check (model counts + best-effort PCIe link info) ─────────────────────

function Convert-LinkSpeedToGb {
    param([Parameter(Mandatory=$true)]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [int64] -or $Value -is [uint64] -or $Value -is [double] -or $Value -is [decimal]) {
        return [math]::Round(([double]$Value / 1e9), 1)
    }
    if ($Value -is [string]) {
        $s = $Value.Trim()
        if ($s -match '^\s*([\d\.]+)\s*Gbps\s*$') { return [double]$matches[1] }
        if ($s -match '^\s*([\d\.]+)\s*Mbps\s*$') { return [math]::Round(([double]$matches[1] / 1000), 1) }
        if ($s -match '^\s*([\d\.]+)\s*bps\s*$')  { return [math]::Round(([double]$matches[1] / 1e9),  1) }
        if ($s -match '^\s*([\d\.]+)\s*$')         { return [math]::Round(([double]$matches[1] / 1e9),  1) }
        return $null
    }
    return $null
}

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
            PcieGen              = if ($link) { $link.Gen }        else { 'Unknown' }
            PcieWidth            = if ($link) { $link.Width }      else { 'Unknown' }
            PcieSpeed            = if ($link) { $link.SpeedGTs }   else { 'Unknown' }
            PcieApproxGBs        = if ($link) { $link.ApproxGBs }  else { 'Unknown' }
        }
    }
    $detail = ($rows | Format-Table -AutoSize | Out-String).TrimEnd()

    $groups     = $rows | Group-Object InterfaceDescription
    $counts     = foreach ($g in $groups | Sort-Object Name) {
        [pscustomobject]@{ Model=$g.Name; Count=$g.Count }
    }
    $countsText = ($counts | Format-Table -AutoSize | Out-String).TrimEnd()

    return ("NICs (all physical):`r`n{0}`r`n`r`nCounts by model:`r`n{1}" -f $detail, $countsText)
}
function Get-Nic-Scalar {
    $objs  = @( Get-Nic-Objects )
    $pairs = @()
    $groups = $objs | Group-Object InterfaceDescription
    foreach ($g in $groups) {
        $name   = if ($null -ne $g.Name) { $g.Name.Trim() } else { 'UnknownModel' }
        $pairs += ("{0}|{1}" -f $name, $g.Count)
    }
    ($pairs | Sort-Object) -join ' ; '
}
function Invoke-NicCheck {
    $_current_text   = Get-Nic-Text
    $_current_scalar = Get-Nic-Scalar
    $_golden_scalar  = Ensure-Golden -_golden_file_name 'golden_nic_model_count.log' -_current_scalar $_current_scalar
    $_is_match       = ($_current_scalar -eq $_golden_scalar)
    [pscustomobject]@{
        name           = 'nic_model_counts'
        result_tag     = if ($_is_match) { 'PASS' } else { 'FAIL' }
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
        $model = if ($d.PSObject.Properties.Name -contains 'Model' -and $d.Model)             { $d.Model.ToString().Trim() }
                 elseif ($d.PSObject.Properties.Name -contains 'FriendlyName' -and $d.FriendlyName) { $d.FriendlyName.ToString().Trim() }
                 else { 'UnknownModel' }
        $bus   = if ($d.PSObject.Properties.Name -contains 'BusType' -and $d.BusType)         { $d.BusType.ToString().Trim() }
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

    $pairs  = foreach ($r in $rows) { "{0}|{1}" -f $r.Model, $r.Bus }
    $groups = $pairs | Group-Object
    $counts = foreach ($g in $groups | Sort-Object Name) {
        $tok = $g.Name.Split('|', 2)
        [pscustomobject]@{ Model=$tok[0]; Bus=$tok[1]; Count=$g.Count }
    }
    $countsText = ($counts | Format-Table -AutoSize | Out-String).TrimEnd()

    return ("Storage devices:`r`n{0}`r`n`r`nCounts by model+bus:`r`n{1}" -f $detail, $countsText)
}
function Get-Storage-Scalar {
    $objs  = @( Get-Storage-Objects )
    $pairs = @()
    foreach ($d in $objs) {
        $model = if ($d.PSObject.Properties.Name -contains 'Model' -and $d.Model)                  { $d.Model.ToString().Trim() }
                 elseif ($d.PSObject.Properties.Name -contains 'FriendlyName' -and $d.FriendlyName) { $d.FriendlyName.ToString().Trim() }
                 else { 'UnknownModel' }
        $bus   = if ($d.PSObject.Properties.Name -contains 'BusType' -and $d.BusType)              { $d.BusType.ToString().Trim() }
                 elseif ($d.PSObject.Properties.Name -contains 'InterfaceType' -and $d.InterfaceType) { $d.InterfaceType.ToString().Trim() }
                 else { 'UnknownBus' }
        $pairs += ("{0}|{1}" -f $model, $bus)
    }
    $groups = $pairs | Group-Object
    $rows   = foreach ($g in $groups) { "{0}|{1}" -f $g.Name, $g.Count }
    ($rows | Sort-Object) -join ' ; '
}
function Invoke-StorageCheck {
    $_current_text   = Get-Storage-Text
    $_current_scalar = Get-Storage-Scalar
    $_golden_scalar  = Ensure-Golden -_golden_file_name 'golden_storage_model_bus_count.log' -_current_scalar $_current_scalar
    $_is_match       = ($_current_scalar -eq $_golden_scalar)
    [pscustomobject]@{
        name           = 'storage_model_bus_counts'
        result_tag     = if ($_is_match) { 'PASS' } else { 'FAIL' }
        content_text   = $_current_text
        golden_scalar  = $_golden_scalar
        current_scalar = $_current_scalar
    }
}

# ── Combined per-run log + summary ────────────────────────────────────────────

function Write-CombinedPerRunLog {
    param(
        [Parameter(Mandatory)][int]   $_count,
        [Parameter(Mandatory)][string]$_date2,
        [Parameter(Mandatory)][string]$_overall_tag,
        [Parameter(Mandatory)][object]$_results
    )
    $_file_path = Join-Path $_log_path ("{0}_{1}_{2}.log" -f $_count, $_date2, $_overall_tag)

    $lines  = @()
    $lines += ("COUNT: {0}" -f $_count)
    $lines += ("DATE2: {0}" -f $_date2)
    $lines += ("OVERALL: {0}" -f $_overall_tag)
    $lines += ""

    foreach ($_r in $_results) {
        $lines += ("== CHECK: {0} ==" -f $_r.name)
        $lines += ("RESULT: {0}"  -f $_r.result_tag)
        $lines += ("GOLDEN: {0}"  -f $_r.golden_scalar)
        $lines += ("CURRENT: {0}" -f $_r.current_scalar)
        $lines += ""
        $lines += ($_r.content_text.Split("`n"))
        $lines += ""
    }
    $lines -join "`r`n" | Set-Content -Path $_file_path -Encoding UTF8
    return $_file_path
}

function Append-CombinedSummary {
    param(
        [Parameter(Mandatory)][int]   $_count,
        [Parameter(Mandatory)][string]$_date2,
        [Parameter(Mandatory)][string]$_overall_tag,
        [Parameter(Mandatory)][object]$_results
    )
    Add-Content -Path $_summary_file -Value ("{0}`t{1}`t{2}" -f $_count, $_date2, $_overall_tag)
    Add-Content -Path $_summary_file -Value ""

    foreach ($_r in $_results) {
        Add-Content -Path $_summary_file -Value ("[ {0} ] RESULT: {1}" -f $_r.name, $_r.result_tag)
        Add-Content -Path $_summary_file -Value ("GOLDEN={0}"  -f $_r.golden_scalar)
        Add-Content -Path $_summary_file -Value ("CURRENT={0}" -f $_r.current_scalar)
        Add-Content -Path $_summary_file -Value ""
        $_r.content_text.Split("`n") | ForEach-Object { Add-Content -Path $_summary_file -Value $_ }
        Add-Content -Path $_summary_file -Value ""
    }
    Add-Content -Path $_summary_file -Value "`n`n`n"
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

$failing      = @($_results | Where-Object { $_.result_tag -ne 'PASS' })
$_overall_tag = if ($failing.Count -eq 0) { 'PASS' } else { 'FAIL' }

$_per_run_path = Write-CombinedPerRunLog `
    -_count $_count -_date2 $_date2 -_overall_tag $_overall_tag -_results $_results
Append-CombinedSummary `
    -_count $_count -_date2 $_date2 -_overall_tag $_overall_tag -_results $_results

Write-Host ("Overall: {0}" -f $_overall_tag)
Write-Host ("Per-run log : {0}" -f $_per_run_path)
Write-Host ("Summary log : {0}" -f $_summary_file)
