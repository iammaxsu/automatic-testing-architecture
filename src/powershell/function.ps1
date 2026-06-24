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

$_function_ps1_api = '00.00.04'

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

function Resolve-PciAncestor {
    param([Parameter(Mandatory)][string]$InstanceId)
    $iid = $InstanceId
    for ($i = 0; $i -lt 10 -and $null -ne $iid -and $iid -ne ''; $i++) {
        if ($iid -like 'PCI\*') { return $iid }
        $iid = Get-ParentInstanceId -InstanceId $iid
    }
    return $null
}

# Coerce any numeric-ish PnP property value to a plain [int].
# Get-PnpDeviceProperty returns PCIe link properties as [uint32]; a bare
# "$v -is [int]" test is FALSE for [uint32], which silently dropped real
# values to 0 (the original Gen1/Unknown bug). Cast through [int] instead.
function ConvertTo-IntOrZero {
    param($Value)
    if ($null -eq $Value) { return 0 }
    try {
        if ($Value -is [string]) {
            if ($Value -match '(\d+)') { return [int]$matches[1] }
            return 0
        }
        return [int]$Value      # works for uint32/uint16/byte/int64/double
    } catch { return 0 }
}

# DEVPKEY_PciDevice_*LinkSpeed is an encoded enum, NOT a GT/s value:
#   1 = 2.5  2 = 5.0  3 = 8.0  4 = 16.0  5 = 32.0  6 = 64.0  (GT/s)
# (matches the PCIe Link Status "Current Link Speed" field; CheckPCIe.ps1
# dumps the same raw codes.) Values >6 are treated as already-GT/s for
# defensiveness against a stack that pre-decodes them.
function ConvertFrom-PcieSpeedCode {
    param([int]$Code)
    switch ($Code) {
        1 { return 2.5 }
        2 { return 5.0 }
        3 { return 8.0 }
        4 { return 16.0 }
        5 { return 32.0 }
        6 { return 64.0 }
        default {
            if ($Code -gt 6) { return [double]$Code }
            return 0.0
        }
    }
}

function ConvertTo-PcieGen {
    param([double]$SpeedGTs)
    if    ($SpeedGTs -le  0) { return 'Unknown' }
    elseif ($SpeedGTs -lt  3) { return 'Gen1' }
    elseif ($SpeedGTs -lt  6) { return 'Gen2' }
    elseif ($SpeedGTs -lt 12) { return 'Gen3' }
    elseif ($SpeedGTs -lt 24) { return 'Gen4' }
    elseif ($SpeedGTs -lt 40) { return 'Gen5' }
    elseif ($SpeedGTs -lt 70) { return 'Gen6' }
    else                      { return 'Gen-Unknown' }
}

function Get-PcieLinkBandwidth {
    param([double]$SpeedGTs, [int]$Width)
    if ($Width -lt 1) { $Width = 1 }
    $eff  = if ($SpeedGTs -lt 8.1) { 0.8 } else { (128.0 / 130.0) }
    $gbps = $Width * $SpeedGTs * $eff
    return [math]::Round($gbps / 8.0, 3)
}

function Get-PcieLinkInfo {
    param([Parameter(Mandatory)][string]$InstanceIdOrChild)
    $pci = if ($InstanceIdOrChild -like 'PCI\*') { $InstanceIdOrChild }
            else { Resolve-PciAncestor -InstanceId $InstanceIdOrChild }
    if (-not $pci) { return $null }

    # Read BOTH the negotiated (Current*) and the device-capability (Max*)
    # link properties so the report can show current AND maximum PCIe ability.
    $curSpdRaw = Get-PnpProp -InstanceId $pci -KeyName 'DEVPKEY_PciDevice_CurrentLinkSpeed'
    $curWidRaw = Get-PnpProp -InstanceId $pci -KeyName 'DEVPKEY_PciDevice_CurrentLinkWidth'
    $maxSpdRaw = Get-PnpProp -InstanceId $pci -KeyName 'DEVPKEY_PciDevice_MaxLinkSpeed'
    $maxWidRaw = Get-PnpProp -InstanceId $pci -KeyName 'DEVPKEY_PciDevice_MaxLinkWidth'
    if ($null -eq $curSpdRaw -and $null -eq $curWidRaw -and
        $null -eq $maxSpdRaw -and $null -eq $maxWidRaw) { return $null }

    $curSpeedGTs = ConvertFrom-PcieSpeedCode -Code (ConvertTo-IntOrZero $curSpdRaw)
    $maxSpeedGTs = ConvertFrom-PcieSpeedCode -Code (ConvertTo-IntOrZero $maxSpdRaw)
    $curWidth    = ConvertTo-IntOrZero $curWidRaw
    $maxWidth    = ConvertTo-IntOrZero $maxWidRaw

    $curGen = ConvertTo-PcieGen -SpeedGTs $curSpeedGTs
    $maxGen = ConvertTo-PcieGen -SpeedGTs $maxSpeedGTs
    $curGBs = Get-PcieLinkBandwidth -SpeedGTs $curSpeedGTs -Width $curWidth
    $maxGBs = Get-PcieLinkBandwidth -SpeedGTs $maxSpeedGTs -Width $maxWidth

    # Gen and Speed are the same fact in two notations (Gen4 == 16.0 GT/s),
    # so they are merged into one display string instead of two columns.
    $curGenSpeed = if ($curGen -ne 'Unknown' -and $curSpeedGTs -gt 0) { '{0} ({1:0.0} GT/s)' -f $curGen, $curSpeedGTs }
                   else { 'Unknown' }
    $maxGenSpeed = if ($maxGen -ne 'Unknown' -and $maxSpeedGTs -gt 0) { '{0} ({1:0.0} GT/s)' -f $maxGen, $maxSpeedGTs }
                   else { 'Unknown' }
    $genSpeedText = if ($curGenSpeed -ne 'Unknown' -and $maxGenSpeed -ne 'Unknown') {
                        if ($curGenSpeed -eq $maxGenSpeed) { $curGenSpeed } else { '{0} (max {1})' -f $curGenSpeed, $maxGenSpeed } }
                    elseif ($curGenSpeed -ne 'Unknown') { $curGenSpeed }
                    elseif ($maxGenSpeed -ne 'Unknown') { 'Unknown (max {0})' -f $maxGenSpeed }
                    else { 'Unknown' }

    $widText = if ($curWidth -gt 0 -and $maxWidth -gt 0) {
                   if ($curWidth -eq $maxWidth) { "x$curWidth" } else { 'x{0} (max x{1})' -f $curWidth, $maxWidth } }
               elseif ($curWidth -gt 0) { "x$curWidth" }
               elseif ($maxWidth -gt 0) { 'Unknown (max x{0})' -f $maxWidth }
               else { 'Unknown' }

    [pscustomobject]@{
        InstanceId       = $pci
        CurSpeedGTs      = $curSpeedGTs
        MaxSpeedGTs      = $maxSpeedGTs
        CurWidth         = $curWidth
        MaxWidth         = $maxWidth
        CurGen           = $curGen
        MaxGen           = $maxGen
        # Display fields consumed by the NIC/storage tables. TheoreticalGBs is
        # the PCIe link's raw byte-throughput ceiling derived from Gen x Width
        # (encoding-efficiency adjusted) -- it is the slot/lane capacity, not a
        # measured value and not comparable to a NIC's Ethernet line rate; a
        # link is routinely provisioned well above what one port needs.
        GenSpeed         = $genSpeedText
        Width            = $widText
        TheoreticalGBs   = if ($curGBs -gt 0) { '~{0} GB/s (per dir)' -f $curGBs } else { 'Unknown' }
        MaxTheoreticalGBs = if ($maxGBs -gt 0) { '~{0} GB/s (per dir)' -f $maxGBs } else { 'Unknown' }
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

# Best-effort negotiated SATA link speed (e.g. "6.0 Gb/s" for SATA Gen3) for
# one physical disk.
#
# There is no documented Windows DEVPKEY or WMI class exposing the AHCI
# host port's raw negotiated-speed register (PxSSTS) independent of the
# device -- tools that show that "raw" value (e.g. CrystalDiskInfo's
# advanced mode) do so via a third-party kernel driver doing direct PCI BAR
# MMIO reads, which is out of scope here. The practical, documented source
# is the disk's own ATA IDENTIFY data, surfaced by smartctl's
# "SATA Version is: <proto>, <max> Gb/s (current: <cur> Gb/s)" line -- the
# same source dev_detect.sh already falls back to (see sata_summarize_dev)
# when its preferred /sys/class/ata_link/*/sata_spd reading is unavailable.
#
# This is not a meaningful loss of precision for SATA specifically: unlike
# PCIe (multiple lanes/devices can sit behind one upstream link) or USB
# (devices share a hub's upstream link), SATA is point-to-point -- exactly
# one device per port/channel -- so the device's self-reported negotiated
# speed and the channel's negotiated speed are definitionally the same
# value, not just a proxy for it.
function Get-SataLinkInfo {
    param([Parameter(Mandatory)][int]$PhysicalDriveIndex)
    $result = [pscustomobject]@{
        Proto     = $null
        MaxSpeed  = $null   # Gb/s, [double]
        CurSpeed  = $null   # Gb/s, [double]
        CurLabel  = 'Unknown'
        Source    = 'none'
    }
    $smartctl = Get-Command smartctl -ErrorAction SilentlyContinue
    if (-not $smartctl) { return $result }
    $dev = "\\.\PhysicalDrive$PhysicalDriveIndex"
    $out = & $smartctl.Source -i $dev 2>$null
    if (-not $out) { return $result }
    $line = $out | Where-Object { $_ -match 'SATA Version is:' } | Select-Object -First 1
    if (-not $line) { return $result }
    # "SATA Version is:  SATA 3.2, 6.0 Gb/s (current: 6.0 Gb/s)"
    if ($line -match 'SATA Version is:\s*([^,]+),\s*([\d.]+)\s*Gb/s\s*\(current:\s*([\d.]+)\s*Gb/s\)') {
        $result.Proto    = $matches[1].Trim()
        $result.MaxSpeed = [double]$matches[2]
        $result.CurSpeed = [double]$matches[3]
        $result.CurLabel = '{0:0.0} Gb/s' -f $result.CurSpeed
        $result.Source   = 'smartctl'
    }
    return $result
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
    # StrictMode-safe: $_date2 may be unset if config.ps1 was not loaded.
    $d = Get-Variable -Name '_date2' -ValueOnly -ErrorAction SilentlyContinue
    if ($d -and -not [string]::IsNullOrWhiteSpace([string]$d)) { return [string]$d }
    return (Get-Date -Format 'yyyyMMddTHHmmss')   # ISO 8601 basic, local (LOG022)
}

function Get-NextCount {
    # StrictMode-safe: $_newcount may be unset if the caller did not provide it.
    $nc = Get-Variable -Name '_newcount' -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $nc -and (($nc -as [int]) -ne $null)) {
        return [int]$nc
    }
    $count = 1
    if (Test-Path $_counter_file) {
        $raw = Get-Content $_counter_file -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($raw -match '^\d+$') { $count = [int]$raw + 1 }
    }
    $count | Set-Content -Path $_counter_file -Encoding UTF8
    return $count
}

function Initialize-Golden {
    param(
        [Parameter(Mandatory)][string]$GoldenFileName,
        [Parameter(Mandatory)][string]$CurrentScalar
    )
    $goldenPath = Join-Path $_log_path $GoldenFileName
    $needInit = $true
    if (Test-Path $goldenPath) {
        $raw = Get-Content $goldenPath -Raw -ErrorAction SilentlyContinue
        if ($null -ne $raw -and ($raw -match '\S')) { $needInit = $false }
    }
    if ($needInit) {
        $CurrentScalar | Set-Content -Path $goldenPath -Encoding UTF8
        Write-Host "  Initialized golden: $goldenPath"
    }
    # DET013: callers need to know "just created" so they can report INIT
    # rather than a Pass that never actually verified anything.
    $script:_golden_was_init = $needInit
    return ((Get-Content $goldenPath -Raw) -replace "`r", "").Trim()
}

function Write-CombinedPerRunLog {
    param(
        [Parameter(Mandatory)][int]   $Count,
        [Parameter(Mandatory)][string]$Date2,
        [Parameter(Mandatory)][string]$OverallTag,
        [Parameter(Mandatory)][object]$Results
    )
    $filePath = Join-Path $_log_path ('{0}_{1}_{2}.log' -f $Count, $Date2, $OverallTag)
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
    $lines -join "`r`n" | Set-Content -Path $filePath -Encoding UTF8
    return $filePath
}

function Add-CombinedSummary {
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

# -- 5. Tool installation helpers ----------------------------------------------
# Mirrors function.sh __pkg_install / iperf3_install for Windows package managers.
# Called from test scripts to ensure a required tool is present before testing.

# Reload PATH from Machine + User registry values so a tool installed in this
# session (via winget/choco/scoop) becomes resolvable without opening a new shell.
function Update-PathFromEnv {
    $m = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $u = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:PATH = (@($m, $u) | Where-Object { $_ -and $_ -ne '' }) -join ';'
}

# Like function.sh iperf3_install: already in PATH -> use it; missing -> install.
# Returns the resolved iperf3.exe path, or $null if all methods fail.
# Install fan-out (closest to bash __pkg_install apt-get/dnf/yum order):
#   0. Local offline cache: a copy already unpacked into ToolsDir\iperf3 (placed
#      manually, or left over from a previous successful download) -- checked
#      first so an offline DUT never needs network access on subsequent runs.
#   1. winget  (built into Win10 1809+/11)
#   2. Chocolatey
#   3. Scoop
#   4. Portable-zip download from a GitHub release (no-package-manager fallback;
#      unpacked into ToolsDir\iperf3 and prepended to PATH for this session only)
function Ensure-Iperf3 {
    param(
        [int]    $AutoInstall = 1,
        [string] $WingetId   = 'ar51an.iPerf3',
        [string] $ChocoPkg   = 'iperf3',
        [string] $ScoopPkg   = 'iperf3',
        [string] $GhRepo     = 'ar51an/iperf3-win-builds',
        [string] $ZipPattern = 'win64.zip',
        [string] $ToolsDir   = $env:TEMP
    )
    $c = Get-Command iperf3 -ErrorAction SilentlyContinue
    if ($null -ne $c) { return $c.Source }
    if ($AutoInstall -ne 1) { return $null }

    Write-Host '         iperf3 missing -- attempting auto-install...' -ForegroundColor Yellow

    # Step 0: offline cache -- e.g. on an air-gapped DUT, copy the iperf3.exe
    # release zip's contents into ToolsDir\iperf3 once (via USB or any reachable
    # machine) and every subsequent run picks it up with no network access.
    $localDir = Join-Path $ToolsDir 'iperf3'
    if (Test-Path $localDir) {
        $localExe = Get-ChildItem -Path $localDir -Filter 'iperf3.exe' -Recurse -ErrorAction SilentlyContinue |
                    Select-Object -First 1
        if ($null -ne $localExe) {
            Write-Host ("         Found cached iperf3 : " + $localExe.FullName) -ForegroundColor DarkGray
            $env:PATH = (Split-Path -Parent $localExe.FullName) + ';' + $env:PATH
            return $localExe.FullName
        }
    }

    if ($WingetId -ne '' -and $null -ne (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host ("         winget install $WingetId") -ForegroundColor DarkGray
        try {
            & winget install --id $WingetId --exact --silent `
                --accept-package-agreements --accept-source-agreements `
                --disable-interactivity 2>&1 | Out-Null
        } catch {}
        Update-PathFromEnv
        $c = Get-Command iperf3 -ErrorAction SilentlyContinue
        if ($null -ne $c) { return $c.Source }
    }
    if ($ChocoPkg -ne '' -and $null -ne (Get-Command choco -ErrorAction SilentlyContinue)) {
        Write-Host ("         choco install $ChocoPkg") -ForegroundColor DarkGray
        try { & choco install $ChocoPkg -y --no-progress 2>&1 | Out-Null } catch {}
        Update-PathFromEnv
        $c = Get-Command iperf3 -ErrorAction SilentlyContinue
        if ($null -ne $c) { return $c.Source }
    }
    if ($ScoopPkg -ne '' -and $null -ne (Get-Command scoop -ErrorAction SilentlyContinue)) {
        Write-Host ("         scoop install $ScoopPkg") -ForegroundColor DarkGray
        try { & scoop install $ScoopPkg 2>&1 | Out-Null } catch {}
        Update-PathFromEnv
        $c = Get-Command iperf3 -ErrorAction SilentlyContinue
        if ($null -ne $c) { return $c.Source }
    }

    # Portable-zip download fallback: no package manager available or all failed.
    if ($GhRepo -eq '') { return $null }
    try {
        $api = "https://api.github.com/repos/$GhRepo/releases/latest"
        $hdr = @{ 'User-Agent' = 'function.ps1'; 'Accept' = 'application/vnd.github+json' }
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.SecurityProtocolType]::Tls12 -bor [Net.ServicePointManager]::SecurityProtocol
        $rel   = Invoke-RestMethod -Uri $api -Headers $hdr -UseBasicParsing
        $asset = @($rel.assets | Where-Object { $_.name -like "*$ZipPattern" } | Select-Object -First 1)
        if ($asset.Count -eq 0) {
            Write-Warning "iperf3: no release asset matching '*$ZipPattern' in $GhRepo latest."
            return $null
        }
        $url  = $asset[0].browser_download_url
        $dest = Join-Path $ToolsDir 'iperf3'
        $zip  = Join-Path $env:TEMP ("iperf3_" + [guid]::NewGuid().ToString('N') + '.zip')
        if (-not (Test-Path $ToolsDir)) { New-Item -ItemType Directory -Path $ToolsDir | Out-Null }
        Write-Host ("         Downloading iperf3 : " + $url) -ForegroundColor DarkGray
        $oldP = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
        try   { Invoke-WebRequest -Uri $url -OutFile $zip -Headers $hdr -UseBasicParsing }
        finally { $ProgressPreference = $oldP }
        if (Test-Path $dest) { Remove-Item $dest -Recurse -Force -ErrorAction SilentlyContinue }
        Expand-Archive -Path $zip -DestinationPath $dest -Force
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
        $exe = Get-ChildItem -Path $dest -Filter 'iperf3.exe' -Recurse -ErrorAction SilentlyContinue |
               Select-Object -First 1
        if ($null -ne $exe) {
            $env:PATH = (Split-Path -Parent $exe.FullName) + ';' + $env:PATH
            return $exe.FullName
        }
    } catch {
        Write-Warning "iperf3 download/extract failed: $($_.Exception.Message)"
    }
    return $null
}
