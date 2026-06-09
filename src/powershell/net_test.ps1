<#
.SYNOPSIS
  Windows network loopback endurance test (NET001-NET013).

.DESCRIPTION
  Enumerates physical Ethernet NICs, pairs them sequentially (NIC[0]<->NIC[1],
  NIC[2]<->NIC[3], ...), then for each pair, at EVERY link speed both NICs
  support (NET004), runs:
    - IPv4 and IPv6 ICMP ping (NET005)
    - iperf3 TCP forward, TCP reverse, UDP forward, UDP reverse (NET006)
    - Verdict: PASS when both TCP directions >= threshold% of link speed (NET009)
  All pairs run in parallel (NET010).

  MULTI-SPEED (NET004)
    Each NIC advertises a set of speeds via the *SpeedDuplex advanced property
    (10 / 100 / 1000 / 2500 / 10000 Mbps, ...).  For each pair the test runs at
    every speed BOTH NICs support, forcing the speed with
    Set-NetAdapterAdvancedProperty and waiting for the link to re-establish
    before measuring.  NICs are restored to Auto Negotiation on exit.
    Currently scoped to Intel controllers/PHYs (-VendorFilter), which expose a
    predictable *SpeedDuplex enumeration.

  ISOLATION MODEL (Windows equivalent of Linux network namespaces, NET002)
    Windows has no network namespaces.  Isolation is achieved by assigning each
    pair a unique private subnet -- 192.247.{idx}.0/24 and fd00:2470::{idx}:0/64
    -- with no default gateway on those IPs.  iperf3 server and client are both
    bound to those addresses, so traffic follows the physical cable path and not
    the OS default route.  Addresses are cleaned up on exit.

  PREREQUISITES
    - Administrator rights (IP + speed changes require elevation).
    - iperf3.exe -- auto-installed if missing (winget / choco / scoop, then a
      portable-zip download), mirroring net_test.sh's iperf3_install.  Override
      via the $_net_iperf3_* keys in config.ps1.
    - NICs physically cabled in pairs for loopback.

  CONFIGURATION (two methods, parameters win) - SET001
    1. Config file : config.ps1 beside this script (or -ConfigFile PATH).
    2. Parameters  : -Loops, -Skip, -Speeds, -VendorFilter, ... (override config).

  ARTEFACTS (in logs\) - FWK028: result.json is the canonical source of truth
    net_test_<ts>.result.json              canonical machine-readable result
    net_test_<ts>.log                      main log (pair START/DONE events)
    net_test_pair<N>_<ts>.log              per-pair detail log
    iPerf3_<ev>_n_<od>_<n>of<m>_<type>_spd<spd>_<ts>.log  per-run (NET013)

.EXAMPLE
  .\net_test.ps1
  .\net_test.ps1 -Loops 3 -Speeds "1000,10000"
  .\net_test.ps1 -Lifeline "Ethernet 4"
  .\net_test.ps1 -DryRun
#>

[CmdletBinding()]
param(
    [int]    $Loops        = 0,    # loop count (0 = use config/default)
    [string] $Skip         = '',   # comma-separated NIC names to exclude (NET011)
    [string] $Speeds       = '',   # 'auto' or e.g. '100,1000' (NET004); '' = config
    [string] $VendorFilter = '',   # only test NICs matching this string ('' = config)
    [int]    $IperfTimeSec = 0,    # iperf3 duration per direction in sec (0 = config)
    [int]    $IperfOmitSec = -1,   # iperf3 ramp-up omit in sec (-1 = config)
    [int]    $TcpPassPct   = 0,    # TCP pass threshold % of link speed (0 = config)
    [int]    $LinkWaitSec  = 0,    # max wait for link after a speed change (0 = config)
    [string] $Lifeline    = '',    # NIC name(s) to exclude, comma-separated (CLI override; prefer $_net_exclude_macs in config, NET012)
    [switch] $DryRun,              # skip actual IP/speed changes and iperf3 runs
    [string] $ConfigFile   = ''    # path to config.ps1 (default: beside this script)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$_script_ver                = '00.00.09'
$_requires_function_ps1_api = '00.00.02'
$_script_root = Split-Path -Parent $MyInvocation.MyCommand.Definition
Write-Host "net_test.ps1 v$_script_ver" -ForegroundColor Cyan

# -- Shared library (function.ps1) ---------------------------------------------
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

# -- Config file (SET001) ------------------------------------------------------
if ($ConfigFile -eq '') { $ConfigFile = Join-Path $_script_root 'config.ps1' }
if (Test-Path $ConfigFile) {
    try {
        . $ConfigFile
        Write-Host ("         Loaded config : $ConfigFile") -ForegroundColor DarkGray
    } catch {
        Write-Warning "Could not load config file '$ConfigFile': $($_.Exception.Message)"
    }
}

function Get-CfgVal {
    param([string]$Name, $Fallback)
    $v = Get-Variable -Name $Name -Scope Script -ErrorAction SilentlyContinue
    if ($null -ne $v -and $null -ne $v.Value -and "$($v.Value)" -ne '') { return $v.Value }
    return $Fallback
}

$cfgLoops        = [int]   (Get-CfgVal '_net_loops'           1)
$cfgIperfTimeSec = [int]   (Get-CfgVal '_net_iperf_time_sec'  60)
$cfgIperfOmitSec = [int]   (Get-CfgVal '_net_iperf_omit_sec'  3)
$cfgTcpPassPct   = [int]   (Get-CfgVal '_net_tcp_pass_pct'    95)
$cfgSpeeds       = [string](Get-CfgVal '_net_speeds'          'auto')
$cfgVendor       = [string](Get-CfgVal '_net_vendor_filter'   'Intel')
$cfgLinkWaitSec  = [int]   (Get-CfgVal '_net_link_wait_sec'   30)
$StrictLifeline  = [int]   (Get-CfgVal '_net_strict_lifeline' 1)
$cfgExcludeMacs  = [string](Get-CfgVal '_net_exclude_macs'    '')
$Iperf3AutoInst  = [int]   (Get-CfgVal '_net_iperf3_auto_install' 1)
$Iperf3WingetId  = [string](Get-CfgVal '_net_iperf3_winget_id' 'ar51an.iPerf3')
$Iperf3ChocoPkg  = [string](Get-CfgVal '_net_iperf3_choco_pkg' 'iperf3')
$Iperf3ScoopPkg  = [string](Get-CfgVal '_net_iperf3_scoop_pkg' 'iperf3')
$Iperf3GhRepo    = [string](Get-CfgVal '_net_iperf3_gh_repo'   'ar51an/iperf3-win-builds')
$Iperf3ZipPat    = [string](Get-CfgVal '_net_iperf3_zip_pattern' 'win64.zip')

$Loops        = if ($PSBoundParameters.ContainsKey('Loops')        -and $Loops -gt 0)        { $Loops }        else { $cfgLoops }
$IperfTimeSec = if ($PSBoundParameters.ContainsKey('IperfTimeSec') -and $IperfTimeSec -gt 0) { $IperfTimeSec } else { $cfgIperfTimeSec }
$IperfOmitSec = if ($PSBoundParameters.ContainsKey('IperfOmitSec') -and $IperfOmitSec -ge 0) { $IperfOmitSec } else { $cfgIperfOmitSec }
$TcpPassPct   = if ($PSBoundParameters.ContainsKey('TcpPassPct')   -and $TcpPassPct -gt 0)   { $TcpPassPct }   else { $cfgTcpPassPct }
$LinkWaitSec  = if ($PSBoundParameters.ContainsKey('LinkWaitSec')  -and $LinkWaitSec -gt 0)  { $LinkWaitSec }  else { $cfgLinkWaitSec }
$Speeds       = if ($PSBoundParameters.ContainsKey('Speeds')       -and $Speeds -ne '')      { $Speeds }       else { $cfgSpeeds }
$VendorFilter = if ($PSBoundParameters.ContainsKey('VendorFilter'))                          { $VendorFilter } else { $cfgVendor }
if ($Loops -le 0) { $Loops = 1 }

# Parse explicit speed allow-list (empty / 'auto' = no restriction).
$_speedAllow = @()
if ($Speeds -ne '' -and $Speeds -ne 'auto') {
    $_speedAllow = @($Speeds -split '[,;]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ })
}

# -- Paths & small helpers -----------------------------------------------------
$_log_path = Join-Path $_script_root 'logs'
if (-not (Test-Path $_log_path)) { New-Item -Path $_log_path -ItemType Directory | Out-Null }

function Now-Iso { Get-Date -Format 'yyyy-MM-ddTHH:mm:ss' }
function Now-Ts  { Get-Date -Format 'yyyyMMddTHHmmss' }

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

# Render a self-contained HTML report from the PSCustomObject parsed out of
# result.json.  FWK028: result.json is canonical; HTML is a derived view only.
function Write-HtmlReport {
    param($Result, [string]$OutPath)
    $ov  = [string]$Result.overall_verdict
    $ovc = switch ($ov) { 'PASS' { '#2ea043' } 'FAIL' { '#da3633' } default { '#e3b341' } }
    $s   = $Result.summary
    $cfg = $Result.config
    $css = 'body{font-family:Consolas,monospace;background:#0d1117;color:#c9d1d9;margin:24px 32px}' +
           'h1,h2,h3{color:#58a6ff}h2{border-bottom:1px solid #30363d;padding-bottom:4px;margin-top:28px}' +
           'table{border-collapse:collapse;width:100%;margin-bottom:12px}' +
           'th{background:#161b22;color:#8b949e;padding:6px 10px;text-align:left;border:1px solid #30363d}' +
           'td{padding:5px 10px;border:1px solid #21262d}tr:nth-child(even) td{background:#161b22}' +
           '.pass{color:#2ea043;font-weight:bold}.fail{color:#da3633;font-weight:bold}' +
           '.unknown{color:#e3b341;font-weight:bold}.na{color:#6e7681}.skip{color:#6e7681}' +
           '.badge{display:inline-block;padding:3px 14px;border-radius:4px;color:#fff;font-weight:bold}'
    $sb = [System.Text.StringBuilder]::new(8192)
    [void]$sb.Append('<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">')
    [void]$sb.Append('<title>net_test ' + $Result.session_id + '</title>')
    [void]$sb.Append('<style>' + $css + '</style></head><body>')
    [void]$sb.Append('<h1>Network Test Report</h1>')
    [void]$sb.Append('<p>Host: <b>' + $cfg.dut_host + '</b> &nbsp;|&nbsp; Session: ' + $Result.session_id + '</p>')
    [void]$sb.Append('<p>Vendor filter: <b>' + $cfg.vendor_filter + '</b> &nbsp;|&nbsp; Loops: ' + $cfg.loops +
                     ' &nbsp;|&nbsp; iperf3 time: ' + $cfg.iperf_time_sec + 's &nbsp;|&nbsp; omit: ' +
                     $cfg.iperf_omit_sec + 's &nbsp;|&nbsp; TCP pass: ' + $cfg.tcp_pass_pct + '%</p>')
    [void]$sb.Append('<p>Overall: <span class="badge" style="background:' + $ovc + '">' + $ov + '</span></p>')
    [void]$sb.Append('<h2>Summary</h2>')
    [void]$sb.Append('<table><tr><th>Total</th><th>Pass</th><th>Fail</th><th>Unknown</th><th>N/A+Skipped</th></tr><tr>')
    [void]$sb.Append('<td>'               + $s.total   + '</td>')
    [void]$sb.Append('<td class="pass">'  + $s.passed  + '</td>')
    [void]$sb.Append('<td class="fail">'  + $s.failed  + '</td>')
    [void]$sb.Append('<td class="unknown">' + $s.unknown + '</td>')
    [void]$sb.Append('<td class="na">'    + $s.skipped + '</td>')
    [void]$sb.Append('</tr></table>')
    [void]$sb.Append('<h2>Pairs</h2>')
    foreach ($pair in $Result.details.pairs) {
        [void]$sb.Append('<h3>' + $pair.name + '</h3>')
        if ($pair.skip_reason) {
            [void]$sb.Append('<p class="skip">Skipped: ' + $pair.skip_reason + '</p>')
            continue
        }
        [void]$sb.Append('<table><tr><th>Speed (Mbps)</th><th>IPv4 Ping</th><th>IPv6 Ping</th>')
        [void]$sb.Append('<th>TCP Fwd (M)</th><th>TCP Rev (M)</th><th>UDP Fwd (M)</th><th>UDP Rev (M)</th><th>Verdict</th></tr>')
        foreach ($spd in $pair.speeds) {
            $vc = switch ([string]$spd.verdict) { 'PASS' { 'pass' } 'FAIL' { 'fail' } 'UNKNOWN' { 'unknown' } default { 'na' } }
            $t  = $spd.throughput
            $nr = if ($spd.na_reason) { '<br><small>' + $spd.na_reason + '</small>' } else { '' }
            [void]$sb.Append('<tr>')
            [void]$sb.Append('<td>' + $spd.speed_mbps + '</td>')
            [void]$sb.Append('<td class="' + $vc + '">' + $spd.ipv4_ping + '</td>')
            [void]$sb.Append('<td class="' + $vc + '">' + $spd.ipv6_ping + '</td>')
            [void]$sb.Append('<td>' + $t.tcp_fwd_mbps + '</td>')
            [void]$sb.Append('<td>' + $t.tcp_rev_mbps + '</td>')
            [void]$sb.Append('<td>' + $t.udp_fwd_mbps + '</td>')
            [void]$sb.Append('<td>' + $t.udp_rev_mbps + '</td>')
            [void]$sb.Append('<td class="' + $vc + '">' + $spd.verdict + $nr + '</td>')
            [void]$sb.Append('</tr>')
        }
        [void]$sb.Append('</table>')
    }
    [void]$sb.Append('<hr style="border-color:#30363d;margin-top:32px">')
    [void]$sb.Append('<p style="color:#6e7681;font-size:0.85em">net_test.ps1 v' +
                     $script:_script_ver + '  |  ' + $Result.ended_at + '</p>')
    [void]$sb.Append('</body></html>')
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($OutPath, $sb.ToString(), $enc)
}

# Convert a "1.0 Gbps Full Duplex" / "100 Mbps Full Duplex" display string to Mbps.
function ConvertTo-Mbps {
    param([string]$Disp)
    if ($Disp -match '([\d.]+)\s*Gbps') { return [int]([double]$Matches[1] * 1000) }
    if ($Disp -match '([\d.]+)\s*Mbps') { return [int][double]$Matches[1] }
    return 0
}

# Robustly read an adapter's current negotiated speed in Mbps.
# Get-NetAdapter exposes .Speed (uint64 bps) and .LinkSpeed (string "1 Gbps").
function Get-LinkMbps {
    param($Adapter)
    if ($null -eq $Adapter) { return 0 }
    try { if ($Adapter.Speed -gt 0) { return [int]($Adapter.Speed / 1e6) } } catch {}
    return (ConvertTo-Mbps ([string]$Adapter.LinkSpeed))
}

# Enumerate the full-duplex speeds a NIC advertises via *SpeedDuplex.
# Returns an array of @{ mbps=<int>; display=<string> } (excludes Auto/Half).
function Get-NicSpeedOptions {
    param([string]$Nic)
    $out = @()
    try {
        $p = Get-NetAdapterAdvancedProperty -Name $Nic -RegistryKeyword '*SpeedDuplex' -ErrorAction Stop
        $vals = @($p.ValidDisplayValues)
    } catch { return ,$out }
    foreach ($d in $vals) {
        if ($null -eq $d) { continue }
        if ($d -match 'Half') { continue }
        if ($d -match 'Auto') { continue }
        $m = ConvertTo-Mbps $d
        if ($m -gt 0) { $out += @{ mbps = $m; display = $d } }
    }
    return ,$out
}

# -- Admin check ---------------------------------------------------------------
$_isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
            ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $_isAdmin -and -not $DryRun) {
    Write-Error "net_test.ps1 requires Administrator rights for IP/speed changes.`nRe-run from an elevated PowerShell prompt."
    exit 1
}

# -- iperf3 check + auto-install (NET006) --------------------------------------
# Like net_test.sh's iperf3_install: use it if present, otherwise install it.
if (-not $DryRun) {
    $i3path = Ensure-Iperf3 `
        -AutoInstall $Iperf3AutoInst `
        -WingetId    $Iperf3WingetId `
        -ChocoPkg    $Iperf3ChocoPkg `
        -ScoopPkg    $Iperf3ScoopPkg `
        -GhRepo      $Iperf3GhRepo `
        -ZipPattern  $Iperf3ZipPat `
        -ToolsDir    (Join-Path $_script_root 'tools')
    if ($null -eq $i3path) {
        Write-Error ("iperf3 not found and auto-install failed.`n" +
            "Install it manually (winget install --id $Iperf3WingetId) or download from`n" +
            "https://iperf.fr/iperf-download.php and add the folder to PATH, then re-run.")
        exit 1
    }
    Write-Host ("         iperf3         : " + $i3path) -ForegroundColor DarkGray
}

# -- NIC enumeration (NET001) --------------------------------------------------
# Physical Ethernet only (MediaType '802.3'); optionally restricted by vendor.
$_nicObjs = @(Get-NetAdapter -Physical |
    Where-Object { $_.MediaType -eq '802.3' -and $_.Status -ne 'Not Present' })
if ($VendorFilter -ne '') {
    $_nicObjs = @($_nicObjs | Where-Object {
        $_.InterfaceDescription -match [regex]::Escape($VendorFilter) -or
        $_.DriverProvider       -match [regex]::Escape($VendorFilter)
    })
    Write-Host ("         Vendor filter  : '$VendorFilter'") -ForegroundColor DarkGray
}
$_allNics = @($_nicObjs | Sort-Object InterfaceIndex | Select-Object -ExpandProperty Name)

Write-Host ("         Ethernet NICs  : " + ($_allNics -join ', ')) -ForegroundColor DarkGray
if ($_allNics.Count -eq 0) {
    Write-Error "No matching physical Ethernet NICs found (vendor filter: '$VendorFilter')."
    exit 1
}

# -- Management NIC exclusion (NET012) -----------------------------------------
# Priority: 1. MAC list from config ($_net_exclude_macs)
#           2. -Lifeline name(s) from CLI
#           3. Fallback: the NIC carrying the active SSH/RDP session
# The fallback identifies the genuine lifeline by looking at which local IP the
# inbound management connection terminates on -- far more reliable than guessing
# from route metrics (Windows gives faster links lower metrics, so a 10G test NIC
# can outrank the real management NIC).  When the script runs from a local console
# there is no remote session, so nothing is excluded and every NIC is testable.
$_excluded = [System.Collections.Generic.List[string]]::new()

# Step 1: resolve MAC addresses from config to NIC names.
foreach ($rawMac in ($cfgExcludeMacs -split '[,;\s]+' | Where-Object { $_ -ne '' })) {
    $norm = ($rawMac -replace '[-:]', '').ToUpper()
    $a = Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
         Where-Object { ($_.MacAddress -replace '[-:]', '') -ieq $norm } |
         Select-Object -First 1
    if ($null -ne $a) {
        [void]$_excluded.Add($a.Name)
        Write-Host ("         Excl MAC " + $rawMac.PadRight(17) + ": " + $a.Name) -ForegroundColor DarkGray
    } else {
        Write-Warning "NET012: MAC $rawMac not found on this system -- ignored."
    }
}

# Step 2: -Lifeline CLI parameter (name-based; may be comma-separated for multiple NICs).
foreach ($ln in ($Lifeline -split '[,;]+' | Where-Object { $_ -ne '' })) {
    $ln = $ln.Trim()
    if ($ln -ne '' -and -not $_excluded.Contains($ln)) {
        [void]$_excluded.Add($ln)
        Write-Host ("         Excl -Lifeline  : " + $ln) -ForegroundColor DarkGray
    }
}

# Step 3: fallback -- exclude the NIC carrying the active remote session (SSH 22 /
# RDP 3389).  Runs only when nothing was specified above.  Local-console runs have
# no such session, so this correctly excludes nothing.
if ($_excluded.Count -eq 0) {
    try {
        $mgmtPorts = @(22, 3389)
        $sessionIps = @(Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue |
            Where-Object { $mgmtPorts -contains $_.LocalPort -and
                           $_.RemoteAddress -notin @('127.0.0.1', '::1') } |
            Select-Object -ExpandProperty LocalAddress -Unique)
        foreach ($lip in $sessionIps) {
            $own = Get-NetIPAddress -IPAddress $lip -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -ne $own) {
                $nicName = (Get-NetAdapter -InterfaceIndex $own.InterfaceIndex -ErrorAction SilentlyContinue).Name
                if ($null -ne $nicName -and -not $_excluded.Contains($nicName)) {
                    [void]$_excluded.Add($nicName)
                    Write-Host ("         Excl (session)  : $nicName  (carries active SSH/RDP session, local $lip)") -ForegroundColor DarkGray
                }
            }
        }
        if ($_excluded.Count -eq 0) {
            Write-Host ("         Lifeline       : none detected (local console; no NIC excluded)") -ForegroundColor DarkGray
        }
    } catch {}
}

# -- Build skip set (NET011) ---------------------------------------------------
$_skipSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($s in ($Skip -split '[,;]+' | Where-Object { $_ -ne '' })) {
    [void]$_skipSet.Add($s.Trim())
}
foreach ($excl in $_excluded) {
    if ($_skipSet.Contains($excl)) {
        # Already in -Skip; nothing to do.
    } elseif ($_allNics -notcontains $excl) {
        Write-Host ("         Excl            : $excl  (not in vendor-filtered set; already protected)") -ForegroundColor DarkGray
    } else {
        if ($StrictLifeline) {
            Write-Warning "NET012: '$excl' is in the exclusion list and in the test candidate set; removing."
        }
        [void]$_skipSet.Add($excl)
    }
}

$_testNics    = @($_allNics | Where-Object { -not $_skipSet.Contains($_) })
$_skippedNics = @($_allNics | Where-Object {      $_skipSet.Contains($_) })

if ($_testNics.Count -lt 2) {
    Write-Error "Need at least 2 testable NICs; found $($_testNics.Count) after exclusions."
    exit 1
}

# -- Pair NICs: [0]<->[1], [2]<->[3], ... -------------------------------------
$_evenNics     = @()
$_oddNics      = @()
$_unpairedNics = @()
$_pairCount    = [Math]::Floor($_testNics.Count / 2)
for ($i = 0; $i -lt $_pairCount; $i++) {
    $_evenNics += $_testNics[$i * 2]
    $_oddNics  += $_testNics[$i * 2 + 1]
}
if ($_testNics.Count % 2 -eq 1) {
    $_unpairedNics += $_testNics[-1]
    Write-Warning "Odd NIC count -- '$($_testNics[-1])' has no pair and will be skipped (N/A in report)."
}

# -- Per-pair speed plan (NET004) ----------------------------------------------
# A pair is tested at every speed BOTH NICs support, optionally restricted by
# -Speeds.  If neither NIC exposes *SpeedDuplex, fall back to the single
# negotiated speed so the test still runs.
$_pairPlans = @()   # index-aligned with $_evenNics: array of speed-step hashtables
Write-Host ""
for ($i = 0; $i -lt $_evenNics.Count; $i++) {
    $evenOpts = Get-NicSpeedOptions $_evenNics[$i]
    $oddOpts  = Get-NicSpeedOptions $_oddNics[$i]
    $plan = @()
    if ($evenOpts.Count -gt 0 -or $oddOpts.Count -gt 0) {
        $evenMap = @{}; foreach ($o in $evenOpts) { $evenMap[[int]$o.mbps] = $o.display }
        $oddMap  = @{}; foreach ($o in $oddOpts)  { $oddMap[[int]$o.mbps]  = $o.display }
        # Union of both NICs' advertised speeds. Speeds only one NIC supports are
        # included but marked testable=false; the job records them as N/A so the
        # user can see which speeds were considered but skipped.
        $allSpeeds = @(($evenMap.Keys + $oddMap.Keys) | Sort-Object -Unique)
        if ($_speedAllow.Count -gt 0) {
            $allSpeeds = @($allSpeeds | Where-Object { $_speedAllow -contains $_ })
        }
        foreach ($m in $allSpeeds) {
            $testable = $evenMap.ContainsKey($m) -and $oddMap.ContainsKey($m)
            $naReason = $null
            if (-not $testable) {
                if (-not $evenMap.ContainsKey($m)) { $naReason = "$($_evenNics[$i]) does not support ${m}M" }
                else                               { $naReason = "$($_oddNics[$i]) does not support ${m}M" }
            }
            $plan += @{
                mbps        = [int]$m
                testable    = $testable
                evenDisplay = if ($evenMap.ContainsKey($m)) { $evenMap[[int]$m] } else { $null }
                oddDisplay  = if ($oddMap.ContainsKey($m))  { $oddMap[[int]$m]  } else { $null }
                na_reason   = $naReason
            }
        }
    }
    if ($plan.Count -eq 0) {
        # Fallback: single negotiated speed, no speed change.
        $neg = Get-LinkMbps (Get-NetAdapter -Name $_evenNics[$i] -ErrorAction SilentlyContinue)
        if ($neg -le 0) { $neg = 1000 }
        if ($_speedAllow.Count -eq 0 -or $_speedAllow -contains $neg) {
            $plan += @{ mbps = $neg; testable = $true; evenDisplay = $null; oddDisplay = $null; na_reason = $null }
        }
    }
    $_pairPlans += ,$plan
    $spdList = @($plan | ForEach-Object {
        if ($_.testable) { "$($_.mbps)M" } else { "$($_.mbps)M(N/A)" }
    }) -join ', '
    Write-Host ("  Pair $i : " + $_evenNics[$i] + " <-> " + $_oddNics[$i] + "   speeds: [$spdList]") -ForegroundColor Green
}
foreach ($u in $_unpairedNics) { Write-Host ("  Unpaired : $u") -ForegroundColor Yellow }
Write-Host ""
Write-Host ("  Loops: $Loops   iperf3 time: ${IperfTimeSec}s   omit: ${IperfOmitSec}s   TCP pass: ${TcpPassPct}%   link wait: ${LinkWaitSec}s")
Write-Host ""

# -- Main log setup ------------------------------------------------------------
$_runTs   = Now-Ts
$_mainLog = Join-Path $_log_path "net_test_$_runTs.log"

function Write-MainLog { param([string]$Msg)
    "[$(Now-Iso)] $Msg" | Add-Content -Path $_mainLog -Encoding UTF8
}

@(
    "============= Network Test ($_runTs) ============="
    "Host: $($env:COMPUTERNAME)   User: $($env:USERNAME)"
    "Vendor filter: '$VendorFilter'   Loops: $Loops"
    "iperf3 time: ${IperfTimeSec}s   omit: ${IperfOmitSec}s   TCP pass: ${TcpPassPct}%"
    "Mode: parallel pairs ($($_evenNics.Count) pair(s)), multi-speed"
    "======================================================="
) | Out-File -FilePath $_mainLog -Encoding UTF8

# -- Per-pair job scriptblock --------------------------------------------------
# Runs in a separate (elevated) PS process; fully self-contained.
$_pairJobBlock = {
    param(
        [int]    $PairIdx,
        [string] $EvenNic,
        [string] $OddNic,
        [string] $SpeedPlanJson,
        [string] $LogRoot,
        [string] $RunTs,
        [int]    $LoopN,
        [int]    $TotalLoops,
        [int]    $IperfTime,
        [int]    $IperfOmit,
        [int]    $TcpPct,
        [int]    $LinkWait,
        [bool]   $Dry
    )

    function Now-Iso { Get-Date -Format 'yyyy-MM-ddTHH:mm:ss' }

    # SpeedPlan is passed as JSON to avoid Start-Job -ArgumentList flattening.
    # In PS 5.1, ConvertFrom-Json emits the entire JSON array as ONE pipeline item
    # (Object[]).  Wrapping in @() would therefore create a nested array -- do NOT
    # use @() here.  foreach works on both Object[] and a single PSCustomObject.
    $SpeedPlan = $SpeedPlanJson | ConvertFrom-Json
    if ($null -eq $SpeedPlan) { $SpeedPlan = @() }

    function Get-LinkMbpsJob {
        param($Adapter)
        if ($null -eq $Adapter) { return 0 }
        try { if ($Adapter.Speed -gt 0) { return [int]($Adapter.Speed / 1e6) } } catch {}
        $s = [string]$Adapter.LinkSpeed
        if ($s -match '([\d.]+)\s*Gbps') { return [int]([double]$Matches[1] * 1000) }
        if ($s -match '([\d.]+)\s*Mbps') { return [int][double]$Matches[1] }
        return 0
    }

    function Set-NicSpeed {
        param([string]$Nic, [string]$Display, [bool]$Dry)
        if ($Dry -or [string]::IsNullOrEmpty($Display)) { return }
        Set-NetAdapterAdvancedProperty -Name $Nic -RegistryKeyword '*SpeedDuplex' `
            -DisplayValue $Display -ErrorAction SilentlyContinue
    }

    # Wait until both NICs are Up at the requested Mbps.
    function Wait-PairLink {
        param([string]$A, [string]$B, [int]$Mbps, [int]$TimeoutSec, [bool]$Dry)
        if ($Dry) { return $true }
        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        while ((Get-Date) -lt $deadline) {
            $na = Get-NetAdapter -Name $A -ErrorAction SilentlyContinue
            $nb = Get-NetAdapter -Name $B -ErrorAction SilentlyContinue
            if ($na -and $nb -and $na.Status -eq 'Up' -and $nb.Status -eq 'Up' -and
                (Get-LinkMbpsJob $na) -eq $Mbps -and (Get-LinkMbpsJob $nb) -eq $Mbps) {
                return $true
            }
            Start-Sleep -Milliseconds 800
        }
        return $false
    }

    function Add-PairIPs {
        param([int]$Idx, [string]$Even, [string]$Odd, [bool]$Dry)
        if ($Dry) { return }
        $set = @(
            @{ Alias=$Even; IP="192.247.$Idx.1";    PL=24 },
            @{ Alias=$Odd;  IP="192.247.$Idx.11";   PL=24 },
            @{ Alias=$Even; IP="fd00:2470::${Idx}:1";  PL=64 },
            @{ Alias=$Odd;  IP="fd00:2470::${Idx}:11"; PL=64 }
        )
        foreach ($x in $set) {
            try { New-NetIPAddress -InterfaceAlias $x.Alias -IPAddress $x.IP `
                    -PrefixLength $x.PL -ErrorAction Stop | Out-Null } catch {}
        }
    }

    function Invoke-PingCheck {
        param([string]$SrcIp, [string]$DstIp, [bool]$IsV6, [bool]$Dry)
        if ($Dry) { return 'PASS' }
        $a = @('-n','4','-S',$SrcIp)
        if ($IsV6) { $a += '-6' }
        $a += $DstIp
        & ping @a 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { return 'PASS' } else { return 'FAIL' }
    }

    function Start-IperfServer {
        param([string]$BindIp, [int]$Port, [bool]$Dry)
        if ($Dry) { return 0 }
        $p = Start-Process iperf3 -ArgumentList @('--server','--bind',$BindIp,'--port',$Port) `
             -PassThru -WindowStyle Hidden
        Start-Sleep -Seconds 1
        return $p.Id
    }

    function Stop-IperfServer {
        param([int]$ServerPid)
        if ($ServerPid -le 0) { return }
        Stop-Process -Id $ServerPid -Force -ErrorAction SilentlyContinue
    }

    function Invoke-IperfClient {
        param([string]$ClientIp, [string]$ServerIp, [int]$Port, [int]$SpeedM,
              [int]$TimeSec, [int]$Omit, [bool]$Reverse, [bool]$Udp,
              [string]$LogFile, [bool]$Dry)
        if ($Dry) {
            "DRY-RUN iperf3 $ClientIp->$ServerIp tcp=$(-not $Udp) rev=$Reverse ${TimeSec}s" |
                Set-Content $LogFile
            return
        }
        $a = @('--client',$ServerIp,'--bind',$ClientIp,'--port',$Port,
               '--bitrate',"${SpeedM}M",'--time',$TimeSec,
               '--interval','3','--omit',$Omit,'--logfile',$LogFile,'--forceflush')
        if ($Reverse) { $a += '--reverse' }
        if ($Udp)     { $a += '--udp' }
        $p = Start-Process iperf3 -ArgumentList $a -Wait -PassThru -WindowStyle Hidden
        if ($p.ExitCode -ne 0) { "iperf3 client exit $($p.ExitCode)" | Add-Content $LogFile }
    }

    function Get-IperfMbps {
        param([string]$LogFile)
        if (-not (Test-Path $LogFile)) { return 0.0 }
        $raw = Get-Content $LogFile -Raw -ErrorAction SilentlyContinue
        if (-not $raw) { return 0.0 }
        $line = ($raw -split "`n" | Where-Object { $_ -match '\breceiver\b' } | Select-Object -Last 1)
        if (-not $line) { return 0.0 }
        if ($line -match '([\d.]+)\s+([KMG]?)bits/sec') {
            $n = [double]$Matches[1]
            switch ($Matches[2]) {
                'K' { return [Math]::Round($n / 1000, 2) }
                'G' { return [Math]::Round($n * 1000, 2) }
                default { return [Math]::Round($n, 2) }
            }
        }
        return 0.0
    }

    # ---- pair setup ----------------------------------------------------------
    $pair    = "$EvenNic<->$OddNic"
    $v4even  = "192.247.$PairIdx.1";    $v4odd = "192.247.$PairIdx.11"
    $v6even  = "fd00:2470::${PairIdx}:1"; $v6odd = "fd00:2470::${PairIdx}:11"
    $port    = 5201
    $pairLog = Join-Path $LogRoot "net_test_pair${PairIdx}_${RunTs}.log"

    @(
        "============= Pair ${PairIdx}: ${pair} ============="
        "Start: $(Now-Iso)   Iteration: $LoopN/$TotalLoops"
        "Speeds planned: $(@($SpeedPlan | ForEach-Object { if ($_.testable) { "$($_.mbps)M" } else { "$($_.mbps)M(N/A)" } }) -join ', ')"
        "====================================================="
    ) | Set-Content $pairLog

    $speedResults = @()

    try {
        foreach ($step in $SpeedPlan) {
            $mbps = [int]$step.mbps
            "" | Add-Content $pairLog

            # Speed not testable: one NIC in the pair does not support it.
            if (-not [bool]$step.testable) {
                $naReason = [string]$step.na_reason
                "### Speed = $mbps Mbps  [N/A: $naReason]" | Add-Content $pairLog
                $speedResults += @{
                    speed_mbps = $mbps; ipv4_ping='N/A'; ipv6_ping='N/A'
                    throughput=@{tcp_fwd_mbps=0;tcp_rev_mbps=0;udp_fwd_mbps=0;udp_rev_mbps=0}
                    verdict='N/A'; na_reason=$naReason
                }
                continue
            }

            "### Speed = $mbps Mbps" | Add-Content $pairLog

            # Force speed on both NICs and wait for the link to settle.
            Set-NicSpeed -Nic $EvenNic -Display ([string]$step.evenDisplay) -Dry $Dry
            Set-NicSpeed -Nic $OddNic  -Display ([string]$step.oddDisplay)  -Dry $Dry
            $linkOk = Wait-PairLink -A $EvenNic -B $OddNic -Mbps $mbps -TimeoutSec $LinkWait -Dry $Dry

            # (Re-)assert the test IPs; a speed change bounces the link.
            Add-PairIPs -Idx $PairIdx -Even $EvenNic -Odd $OddNic -Dry $Dry
            if (-not $Dry) { Start-Sleep -Seconds 3 }   # NDP / DAD settle

            if (-not $linkOk) {
                "Link did NOT reach $mbps Mbps within ${LinkWait}s - recording UNKNOWN." | Add-Content $pairLog
                $speedResults += @{
                    speed_mbps = $mbps; ipv4_ping='UNKNOWN'; ipv6_ping='UNKNOWN'
                    throughput=@{tcp_fwd_mbps=0;tcp_rev_mbps=0;udp_fwd_mbps=0;udp_rev_mbps=0}
                    verdict='UNKNOWN'
                }
                continue
            }

            $v4Res = Invoke-PingCheck -SrcIp $v4even -DstIp $v4odd -IsV6 $false -Dry $Dry
            "[IPv4 ICMP] $v4even -> $v4odd : $v4Res" | Add-Content $pairLog
            $v6Res = Invoke-PingCheck -SrcIp $v6even -DstIp $v6odd -IsV6 $true -Dry $Dry
            "[IPv6 ICMP] $v6even -> $v6odd : $v6Res" | Add-Content $pairLog

            function Get-Log { param([string]$Type)
                Join-Path $LogRoot "iPerf3_${EvenNic}_n_${OddNic}_${LoopN}of${TotalLoops}_${Type}_spd${mbps}_${RunTs}.log"
            }
            $logTcpRev = Get-Log 'TCPRev'; $logTcpFwd = Get-Log 'TCP'
            $logUdpRev = Get-Log 'UDPRev'; $logUdpFwd = Get-Log 'UDP'

            "[TCP Reverse]" | Add-Content $pairLog
            $srv = Start-IperfServer -BindIp $v4odd -Port $port -Dry $Dry
            Invoke-IperfClient -ClientIp $v4even -ServerIp $v4odd -Port $port -SpeedM $mbps `
                -TimeSec $IperfTime -Omit $IperfOmit -Reverse $true -Udp $false -LogFile $logTcpRev -Dry $Dry
            Stop-IperfServer -ServerPid $srv

            "[TCP Forward]" | Add-Content $pairLog
            $srv = Start-IperfServer -BindIp $v4odd -Port $port -Dry $Dry
            Invoke-IperfClient -ClientIp $v4even -ServerIp $v4odd -Port $port -SpeedM $mbps `
                -TimeSec $IperfTime -Omit $IperfOmit -Reverse $false -Udp $false -LogFile $logTcpFwd -Dry $Dry
            Stop-IperfServer -ServerPid $srv

            "[UDP Reverse]" | Add-Content $pairLog
            $srv = Start-IperfServer -BindIp $v4odd -Port $port -Dry $Dry
            Invoke-IperfClient -ClientIp $v4even -ServerIp $v4odd -Port $port -SpeedM $mbps `
                -TimeSec $IperfTime -Omit $IperfOmit -Reverse $true -Udp $true -LogFile $logUdpRev -Dry $Dry
            Stop-IperfServer -ServerPid $srv

            "[UDP Forward]" | Add-Content $pairLog
            $srv = Start-IperfServer -BindIp $v4odd -Port $port -Dry $Dry
            Invoke-IperfClient -ClientIp $v4even -ServerIp $v4odd -Port $port -SpeedM $mbps `
                -TimeSec $IperfTime -Omit $IperfOmit -Reverse $false -Udp $true -LogFile $logUdpFwd -Dry $Dry
            Stop-IperfServer -ServerPid $srv

            $nTcpFwd = Get-IperfMbps $logTcpFwd
            $nTcpRev = Get-IperfMbps $logTcpRev
            $nUdpFwd = Get-IperfMbps $logUdpFwd
            $nUdpRev = Get-IperfMbps $logUdpRev

            $thr = [Math]::Round($mbps * $TcpPct / 100.0, 2)
            $verdict = 'FAIL'
            if ($v4Res -ne 'PASS' -or $v6Res -ne 'PASS') { $verdict = 'FAIL' }
            elseif ($nTcpFwd -eq 0.0 -or $nTcpRev -eq 0.0) { $verdict = 'UNKNOWN' }
            elseif ($nTcpFwd -ge $thr -and $nTcpRev -ge $thr) { $verdict = 'PASS' }
            else { $verdict = 'FAIL' }

            "Verdict: $verdict  tcpFwd=${nTcpFwd}M tcpRev=${nTcpRev}M udpFwd=${nUdpFwd}M udpRev=${nUdpRev}M thr=${thr}M" |
                Add-Content $pairLog

            $speedResults += @{
                speed_mbps = $mbps; ipv4_ping=$v4Res; ipv6_ping=$v6Res
                throughput=@{ tcp_fwd_mbps=$nTcpFwd; tcp_rev_mbps=$nTcpRev
                              udp_fwd_mbps=$nUdpFwd; udp_rev_mbps=$nUdpRev }
                verdict=$verdict
            }
        }
    } finally {
        # Restore Auto Negotiation so the NICs are usable after the test.
        if (-not $Dry) {
            Set-NetAdapterAdvancedProperty -Name $EvenNic -RegistryKeyword '*SpeedDuplex' `
                -DisplayValue 'Auto Negotiation' -ErrorAction SilentlyContinue
            Set-NetAdapterAdvancedProperty -Name $OddNic -RegistryKeyword '*SpeedDuplex' `
                -DisplayValue 'Auto Negotiation' -ErrorAction SilentlyContinue
            foreach ($ip in @($v4even,$v4odd,$v6even,$v6odd)) {
                Remove-NetIPAddress -IPAddress $ip -Confirm:$false -ErrorAction SilentlyContinue
            }
        }
    }

    "End: $(Now-Iso)" | Add-Content $pairLog
    return @{ name = $pair; speeds = $speedResults }
}

# -- Main run loop -------------------------------------------------------------
$_pairResults = @{}   # name -> @{ name; speeds=[] }

try {
    for ($loop = 1; $loop -le $Loops; $loop++) {
        Write-Host "--- Loop $loop / $Loops ---" -ForegroundColor Cyan
        Write-MainLog "=== Loop $loop/$Loops START - $($_evenNics.Count) pair(s) ==="

        $jobs = @()
        for ($i = 0; $i -lt $_evenNics.Count; $i++) {
            $planJson = ConvertTo-Json -InputObject @($_pairPlans[$i]) -Depth 5 -Compress
            $j = Start-Job -ScriptBlock $_pairJobBlock -ArgumentList @(
                $i, $_evenNics[$i], $_oddNics[$i], $planJson,
                $_log_path, $_runTs, $loop, $Loops,
                $IperfTimeSec, $IperfOmitSec, $TcpPassPct, $LinkWaitSec, ([bool]$DryRun)
            )
            Write-Host ("  [Pair $i] Job $($j.Id) started  " + $_evenNics[$i] + " <-> " + $_oddNics[$i])
            $jobs += $j
        }

        $jobs | Wait-Job | Out-Null

        foreach ($j in $jobs) {
            try {
                $res = Receive-Job -Job $j -ErrorAction Stop
                if ($null -ne $res) {
                    $k = "$($res.name)"
                    if (-not $_pairResults.ContainsKey($k)) {
                        $_pairResults[$k] = @{ name = $res.name; speeds = @() }
                    }
                    $_pairResults[$k].speeds += $res.speeds
                    $nPass = @($res.speeds | Where-Object { $_.verdict -eq 'PASS'    }).Count
                    $nFail = @($res.speeds | Where-Object { $_.verdict -eq 'FAIL'    }).Count
                    $nUnk  = @($res.speeds | Where-Object { $_.verdict -eq 'UNKNOWN' }).Count
                    $nNa   = @($res.speeds | Where-Object { $_.verdict -eq 'N/A'     }).Count
                    $verd  = if ($nFail -gt 0) { 'FAIL' } elseif ($nPass -gt 0) { 'PASS' } elseif ($nUnk -gt 0) { 'UNKNOWN' } else { 'N/A' }
                    $col = 'Yellow'; if ($verd -eq 'PASS') { $col = 'Green' } elseif ($verd -eq 'FAIL') { $col = 'Red' }
                    Write-MainLog "[Pair] DONE  $($res.name)  verdict=$verd  pass=$nPass fail=$nFail unknown=$nUnk na=$nNa"
                    Write-Host ("  [Pair] " + $res.name + "  (pass=$nPass fail=$nFail unknown=$nUnk na=$nNa)") -ForegroundColor $col
                }
            } catch {
                Write-Warning "Job $($j.Id) error: $_"
                Write-MainLog "[Job $($j.Id)] ERROR: $_"
            } finally {
                Remove-Job -Job $j -Force -ErrorAction SilentlyContinue
            }
        }
        Write-MainLog "=== Loop $loop/$Loops DONE ==="
    }
} finally {
    # Backstop: even if a job died, restore speeds + remove test IPs.
    if (-not $DryRun) {
        Write-Host "`nRestoring NICs (Auto Negotiation) and removing test IPs..." -ForegroundColor Cyan
        foreach ($nic in $_testNics) {
            Set-NetAdapterAdvancedProperty -Name $nic -RegistryKeyword '*SpeedDuplex' `
                -DisplayValue 'Auto Negotiation' -ErrorAction SilentlyContinue
        }
        for ($i = 0; $i -lt $_evenNics.Count; $i++) {
            foreach ($ip in @("192.247.$i.1","192.247.$i.11","fd00:2470::${i}:1","fd00:2470::${i}:11")) {
                Remove-NetIPAddress -IPAddress $ip -Confirm:$false -ErrorAction SilentlyContinue
            }
        }
    }
}

# -- Assemble full pairs list for result.json ----------------------------------
$_allPairs = @([array]$_pairResults.Values)

foreach ($u in $_unpairedNics) {
    $_allPairs += @{
        name        = $u
        skip_reason = 'no pair (odd NIC count)'
        speeds      = @(@{ speed_mbps=0; ipv4_ping='N/A'; ipv6_ping='N/A'
                           throughput=@{tcp_fwd_mbps=0;tcp_rev_mbps=0;udp_fwd_mbps=0;udp_rev_mbps=0}
                           verdict='N/A' })
    }
}

$_skipList = @($Skip -split '[,;]+' | Where-Object { $_ -ne '' } | ForEach-Object { $_.Trim() })
foreach ($ex in $_skipList) {
    $_allPairs += @{
        name        = $ex
        skip_reason = '-Skip flag (NET011)'
        speeds      = @(@{ speed_mbps=0; ipv4_ping='SKIPPED'; ipv6_ping='SKIPPED'
                           throughput=@{tcp_fwd_mbps=0;tcp_rev_mbps=0;udp_fwd_mbps=0;udp_rev_mbps=0}
                           verdict='SKIPPED' })
    }
}

# -- Emit result.json (FWK028 / LOG015) ----------------------------------------
$_allSpeedItems = @($_allPairs | ForEach-Object { $_.speeds } | Where-Object { $null -ne $_ })
$_total   = $_allSpeedItems.Count
$_pass    = @($_allSpeedItems | Where-Object { $_.verdict -eq 'PASS'             }).Count
$_fail    = @($_allSpeedItems | Where-Object { $_.verdict -eq 'FAIL'             }).Count
$_unknown = @($_allSpeedItems | Where-Object { $_.verdict -eq 'UNKNOWN'          }).Count
$_skipped = @($_allSpeedItems | Where-Object { $_.verdict -in @('SKIPPED','N/A') }).Count

$_verdict = if   ($_fail -gt 0) { 'FAIL' }
            elseif ($_pass -eq ($_total - $_skipped) -and ($_total - $_skipped) -gt 0) { 'PASS' }
            else { 'UNKNOWN' }

$_result = [ordered]@{
    schema_version  = '1.1'
    test_name       = 'net_test'
    test_version    = $_script_ver
    session_id      = $_runTs
    started_at      = $_runTs
    ended_at        = (Now-Iso)
    config          = [ordered]@{
        dut_host       = $env:COMPUTERNAME
        vendor_filter  = $VendorFilter
        loops          = $Loops
        iperf_time_sec = $IperfTimeSec
        iperf_omit_sec = $IperfOmitSec
        tcp_pass_pct   = $TcpPassPct
    }
    summary         = [ordered]@{
        total=$_total; passed=$_pass; failed=$_fail; unknown=$_unknown; skipped=$_skipped
    }
    overall_verdict = $_verdict
    details         = @{ pairs = $_allPairs }
}

$_resultFile = Join-Path $_log_path "net_test_$_runTs.result.json"
Write-Utf8NoBom -Path $_resultFile -Text ($_result | ConvertTo-Json -Depth 9)

# Generate HTML report (FWK028: render from canonical result.json)
$_reportFile = Join-Path $_log_path "net_test_$_runTs.report.html"
try {
    $_resultObj = Get-Content $_resultFile -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-HtmlReport -Result $_resultObj -Path $_reportFile
} catch {
    Write-Warning "HTML report generation failed: $_"
    $_reportFile = $null
}

Write-Host ""
Write-Host "[INFO] Main log    : $_mainLog"    -ForegroundColor Cyan
Write-Host "[INFO] Result JSON : $_resultFile" -ForegroundColor Cyan
if ($_reportFile) { Write-Host "[INFO] HTML report : $_reportFile" -ForegroundColor Cyan }
$_col = 'Yellow'; if ($_verdict -eq 'PASS') { $_col = 'Green' } elseif ($_verdict -eq 'FAIL') { $_col = 'Red' }
Write-Host "[INFO] Overall     : $_verdict  (pass=$_pass fail=$_fail unknown=$_unknown skipped=$_skipped)" -ForegroundColor $_col
