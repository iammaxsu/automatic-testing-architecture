# function.ps1  -  Windows PowerShell shared utilities for automatic-testing-architecture
#
# Dot-source this file at the top of every Windows test/setup script:
#
#   $_fn = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Definition) 'function.ps1'
#   . $_fn
#   if ($script:_function_ps1_api -lt $_requires_function_ps1_api) {
#       throw "function.ps1 API too old: have $($script:_function_ps1_api), need $_requires_function_ps1_api"
#   }
#
# Scripts in group 4 (test result logging) require the caller to define:
#   $_log_path       -  directory for per-run logs and golden files
#   $_counter_file   -  path to the run counter file
#   $_summary_file   -  path to the appended summary log

Set-StrictMode -Version Latest

# -- Version -------------------------------------------------------------------

$_function_ps1_api = '00.00.01'

# -- 1. Console output helpers -------------------------------------------------

function Write-Step { param([string]$Msg)
    Write-Host "`n=== $Msg ===" -ForegroundColor Cyan }

function Write-OK { param([string]$Msg)
    Write-Host "  [OK]   $Msg" -ForegroundColor Green }

function Write-Skip { param([string]$Msg)
    Write-Host "  [SKIP] $Msg" -ForegroundColor DarkGray }

function Write-Warn { param([string]$Msg)
    Write-Host "  [WARN] $Msg" -ForegroundColor Yellow }

# -- 2. Path resolution --------------------------------------------------------

function Resolve-FirstExisting {
    param([Parameter(Mandatory)][string[]]$Paths)
    foreach ($p in $Paths) { if (Test-Path $p) { return $p } }
    return $null
}

# -- 3. PnP / hardware query helpers ------------------------------------------

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
    $eff  = if ($SpeedGTs -lt 8.1) { 0.8 } else { (128.0 / 130.0) }
    $gbps = $Width * $SpeedGTs * $eff
    return [math]::Round($gbps / 8.0, 3)
}

function Get-PcieLinkInfo {
    param([Parameter(Mandatory)][string]$InstanceIdOrChild)
    $pci = if ($InstanceIdOrChild -like 'PCI\*') { $InstanceIdOrChild }
            else { Ascend-ToPci -InstanceId $InstanceIdOrChild }
    if (-not $pci) { return $null }

    $spd = Get-PnpProp -InstanceId $pci -KeyName 'DEVPKEY_PciDevice_CurrentLinkSpeed'
    $wid = Get-PnpProp -InstanceId $pci -KeyName 'DEVPKEY_PciDevice_CurrentLinkWidth'
    if ($null -eq $spd -and $null -eq $wid) { return $null }

    $speedGTs = 0.0
    if ($spd -is [double] -or $spd -is [single] -or $spd -is [decimal]) { $speedGTs = [double]$spd }
    elseif ($spd -is [int]) { $speedGTs = [double]$spd }
    elseif ($spd -is [string] -and $spd -match '([\d\.]+)') { $speedGTs = [double]$matches[1] }

    $width = 0
    if    ($wid -is [int])                                { $width = $wid }
    elseif ($wid -is [string] -and $wid -match '\d+') { $width = [int]$matches[0] }

    $gen = Parse-PcieGen -SpeedGTs $speedGTs
    $gbs = Approx-PcieGBsPerDir -SpeedGTs $speedGTs -Width $width

    [pscustomobject]@{
        InstanceId = $pci
        SpeedGTs   = if ($speedGTs -gt 0) { '{0:0.0} GT/s' -f $speedGTs } else { 'Unknown' }
        Width      = if ($width -gt 0)    { "x$width" }                   else { 'Unknown' }
        Gen        = $gen
        ApproxGBs  = if ($gbs -gt 0)     { '~{0} GB/s (per dir)' -f $gbs } else { 'Unknown' }
    }
}

function Get-UsbVersionHint {
    param([Parameter(Mandatory)][string]$InstanceId)
    $bcd = Get-PnpProp -InstanceId $InstanceId -KeyName 'DEVPKEY_UsbDevice_BcdUSB'
    if ($bcd) {
        try { return 'USB {0:N2}' -f ([int]$bcd / 256.0) } catch {}
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
    foreach ($k in @('DEVPKEY_Storage_Port_AchievedLinkRate','DEVPKEY_Storage_Port_MaxLinkRate','DEVPKEY_Storage_AchievedLinkRate')) {
        $v = Get-PnpProp -InstanceId $InstanceId -KeyName $k
        if ($v) {
            if ($v -is [string]) {
                if ($v -match '([\d\.]+\s*Gb/s)') { return $matches[1] }
                if ($v -match '(\d+)') { $val = [int]$matches[1]; if ($val -in 1,3,6,12) { return "$val Gb/s" } }
            } elseif ($v -is [int] -and $v -in 1,3,6,12) { return "$v Gb/s" }
            return "$v"
        }
    }
    return $null
}

function Convert-LinkSpeedToGb {
    param([Parameter(Mandatory=$true)]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [int64] -or $Value -is [uint64] -or $Value -is [double] -or $Value -is [decimal]) {
        return [math]::Round([double]$Value / 1e9, 1)
    }
    if ($Value -is [string]) {
        $s = $Value.Trim()
        if ($s -match '^\s*([\d\.]+)\s*Gbps\s*$') { return [double]$matches[1] }
        if ($s -match '^\s*([\d\.]+)\s*Mbps\s*$') { return [math]::Round([double]$matches[1] / 1000, 1) }
        if ($s -match '^\s*([\d\.]+)\s*bps\s*$')  { return [math]::Round([double]$matches[1] / 1e9,  1) }
        if ($s -match '^\s*([\d\.]+)\s*$')         { return [math]::Round([double]$matches[1] / 1e9,  1) }
    }
    return $null
}

# -- 4. Test result logging ----------------------------------------------------
# Requires the calling script to define before dot-sourcing:
#   $_log_path       -  directory for per-run logs and golden files
#   $_counter_file   -  path to the run counter file
#   $_summary_file   -  path to the appended summary log
#
# Get-Date2 and Get-NextCount also read $script:_date2 / $script:_newcount if
# the caller already initialised them (e.g. from a shared config.ps1).

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
        [Parameter(Mandatory)][string]$GoldenFileName,
        [Parameter(Mandatory)][string]$CurrentScalar
    )
    $_golden_path = Join-Path $_log_path $GoldenFileName
    $_need_init = $true
    if (Test-Path $_golden_path) {
        $_raw = Get-Content $_golden_path -Raw -ErrorAction SilentlyContinue
        if ($null -ne $_raw -and ($_raw -match '\S')) { $_need_init = $false }
    }
    if ($_need_init) {
        $CurrentScalar | Set-Content -Path $_golden_path -Encoding UTF8
        Write-Host "  Initialized golden: $_golden_path"
    }
    return ((Get-Content $_golden_path -Raw) -replace "`r", "").Trim()
}

function Write-CombinedPerRunLog {
    param(
        [Parameter(Mandatory)][int]   $Count,
        [Parameter(Mandatory)][string]$Date2,
        [Parameter(Mandatory)][string]$OverallTag,
        [Parameter(Mandatory)][object]$Results
    )
    $_file_path = Join-Path $_log_path ('{0}_{1}_{2}.log' -f $Count, $Date2, $OverallTag)
    $lines  = @()
    $lines += 'COUNT: {0}'   -f $Count
    $lines += 'DATE2: {0}'   -f $Date2
    $lines += 'OVERALL: {0}' -f $OverallTag
    $lines += ''
    foreach ($r in $Results) {
        $lines += '== CHECK: {0} ==' -f $r.name
        $lines += 'RESULT: {0}'      -f $r.result_tag
        $lines += 'GOLDEN: {0}'      -f $r.golden_scalar
        $lines += 'CURRENT: {0}'     -f $r.current_scalar
        $lines += ''
        $lines += $r.content_text.Split("`n")
        $lines += ''
    }
    $lines -join "`r`n" | Set-Content -Path $_file_path -Encoding UTF8
    return $_file_path
}

function Append-CombinedSummary {
    param(
        [Parameter(Mandatory)][int]   $Count,
        [Parameter(Mandatory)][string]$Date2,
        [Parameter(Mandatory)][string]$OverallTag,
        [Parameter(Mandatory)][object]$Results
    )
    Add-Content -Path $_summary_file -Value ('{0}`t{1}`t{2}' -f $Count, $Date2, $OverallTag)
    Add-Content -Path $_summary_file -Value ''
    foreach ($r in $Results) {
        Add-Content -Path $_summary_file -Value ('[ {0} ] RESULT: {1}' -f $r.name, $r.result_tag)
        Add-Content -Path $_summary_file -Value ('GOLDEN={0}'          -f $r.golden_scalar)
        Add-Content -Path $_summary_file -Value ('CURRENT={0}'         -f $r.current_scalar)
        Add-Content -Path $_summary_file -Value ''
        $r.content_text.Split("`n") | ForEach-Object { Add-Content -Path $_summary_file -Value $_ }
        Add-Content -Path $_summary_file -Value ''
    }
    Add-Content -Path $_summary_file -Value "`n`n`n"
}
