<#
.SYNOPSIS
  Windows network loopback endurance test (NET001-NET013).

.DESCRIPTION
  Enumerates physical Ethernet NICs, pairs them sequentially (NIC[0]<->NIC[1],
  NIC[2]<->NIC[3], ...), then for each pair runs:
    - IPv4 and IPv6 ICMP ping (NET005)
    - iperf3 TCP forward, TCP reverse, UDP forward, UDP reverse (NET006)
    - Verdict: PASS when both TCP directions >= threshold% of link speed (NET009)
  All pairs run in parallel (NET010).

  ISOLATION MODEL (Windows equivalent of Linux network namespaces, NET002)
    Windows has no network namespaces.  Isolation is achieved by assigning each
    pair a unique private subnet -- 192.247.{idx}.0/24 and fd00:2470::{idx}:0/64
    -- with no default gateway on those IPs.  iperf3 server and client are both
    bound to those addresses (-S / --bind), so traffic follows the physical cable
    path and not the OS default route.  Addresses are cleaned up on exit.

  PREREQUISITES
    - Administrator rights (IP address assignment requires elevation).
    - iperf3.exe in PATH (https://iperf.fr/iperf-download.php).
    - NICs physically cabled in pairs for loopback.

  CONFIGURATION (two methods, parameters win) - SET001
    1. Config file : config.ps1 beside this script (or -ConfigFile PATH).
    2. Parameters  : -Loops, -Skip, -IperfTimeSec, etc. (override config).

  ARTEFACTS (in logs\) - FWK028: result.json is the canonical source of truth
    net_test_<ts>.result.json              canonical machine-readable result
    net_test_<ts>.log                      main log (pair START/DONE events)
    net_test_pair<N>_<ts>.log              per-pair detail log
    iPerf3_<ev>_n_<od>_<n>of<m>_<type>_spd<spd>_<ts>.log  per-run (NET013)

  NIC SKIP (NET011)
    The NIC carrying the default route (SSH lifeline) is always auto-excluded.
    Additional NICs: -Skip "Ethernet 3,Ethernet 5" (comma-separated names).

.EXAMPLE
  .\net_test.ps1
  .\net_test.ps1 -Loops 3 -Skip "Ethernet 3"
  .\net_test.ps1 -IperfTimeSec 30 -DryRun
#>

[CmdletBinding()]
param(
    [int]    $Loops        = 0,    # loop count (0 = use config/default)
    [string] $Skip         = '',   # comma-separated NIC names to exclude (NET011)
    [int]    $IperfTimeSec = 0,    # iperf3 duration per direction in sec (0 = config)
    [int]    $IperfOmitSec = -1,   # iperf3 ramp-up omit in sec (-1 = config)
    [int]    $TcpPassPct   = 0,    # TCP pass threshold % of link speed (0 = config)
    [switch] $DryRun,              # skip actual IP assignment and iperf3 runs
    [string] $ConfigFile   = ''    # path to config.ps1 (default: beside this script)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$_script_ver  = '00.00.01'
$_script_root = Split-Path -Parent $MyInvocation.MyCommand.Definition
Write-Host "net_test.ps1 v$_script_ver" -ForegroundColor Cyan

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

$cfgLoops          = [int](Get-CfgVal '_net_loops'           1)
$cfgIperfTimeSec   = [int](Get-CfgVal '_net_iperf_time_sec'  60)
$cfgIperfOmitSec   = [int](Get-CfgVal '_net_iperf_omit_sec'  3)
$cfgTcpPassPct     = [int](Get-CfgVal '_net_tcp_pass_pct'    95)
$StrictLifeline    = [int](Get-CfgVal '_net_strict_lifeline' 1)

$Loops        = if ($PSBoundParameters.ContainsKey('Loops')        -and $Loops -gt 0)   { $Loops }        else { $cfgLoops }
$IperfTimeSec = if ($PSBoundParameters.ContainsKey('IperfTimeSec') -and $IperfTimeSec -gt 0)  { $IperfTimeSec } else { $cfgIperfTimeSec }
$IperfOmitSec = if ($PSBoundParameters.ContainsKey('IperfOmitSec') -and $IperfOmitSec -ge 0)  { $IperfOmitSec } else { $cfgIperfOmitSec }
$TcpPassPct   = if ($PSBoundParameters.ContainsKey('TcpPassPct')   -and $TcpPassPct -gt 0)    { $TcpPassPct }   else { $cfgTcpPassPct }
if ($Loops -le 0) { $Loops = 1 }

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

# -- Admin check ---------------------------------------------------------------
$_isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
            ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $_isAdmin -and -not $DryRun) {
    Write-Error "net_test.ps1 requires Administrator rights for IP address assignment.`nRe-run from an elevated PowerShell prompt."
    exit 1
}

# -- iperf3 check --------------------------------------------------------------
if (-not $DryRun) {
    $i3 = Get-Command iperf3 -ErrorAction SilentlyContinue
    if ($null -eq $i3) {
        Write-Error "iperf3 not found in PATH.`nDownload from https://iperf.fr/iperf-download.php and add the folder to PATH."
        exit 1
    }
    Write-Host ("         iperf3         : " + $i3.Source) -ForegroundColor DarkGray
}

# -- NIC enumeration (NET001) --------------------------------------------------
# Physical Ethernet only (MediaType '802.3'). Sorted by InterfaceIndex for a
# stable pairing order across runs on the same machine.
$_allNics = @(Get-NetAdapter -Physical |
    Where-Object { $_.MediaType -eq '802.3' -and $_.Status -ne 'Not Present' } |
    Sort-Object InterfaceIndex |
    Select-Object -ExpandProperty Name)

Write-Host ("         Physical Ethernet NICs : " + ($_allNics -join ', ')) -ForegroundColor DarkGray

if ($_allNics.Count -eq 0) {
    Write-Error "No physical Ethernet NICs found."
    exit 1
}

# -- SSH lifeline detection (NET012) -------------------------------------------
$_lifelineNic = $null
try {
    $r = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
         Sort-Object { $_.RouteMetric + $_.InterfaceMetric } | Select-Object -First 1
    if ($null -ne $r) {
        $_lifelineNic = (Get-NetAdapter -InterfaceIndex $r.InterfaceIndex -ErrorAction SilentlyContinue).Name
    }
} catch {}
if ($null -ne $_lifelineNic) {
    Write-Host ("         SSH lifeline NIC : $_lifelineNic  (auto-excluded)") -ForegroundColor DarkGray
}

# -- Build skip set (NET011) ---------------------------------------------------
$_skipSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($s in ($Skip -split '[,;]+' | Where-Object { $_ -ne '' })) {
    [void]$_skipSet.Add($s.Trim())
}

# NET012: if lifeline NIC is not in explicit skip list, warn or abort.
if ($null -ne $_lifelineNic -and -not $_skipSet.Contains($_lifelineNic)) {
    if ($StrictLifeline) {
        Write-Warning "NET012: lifeline NIC '$_lifelineNic' is not in -Skip. Auto-excluding. To suppress this, add -Skip '$_lifelineNic'."
    }
    [void]$_skipSet.Add($_lifelineNic)
}

$_testNics    = @($_allNics | Where-Object { -not $_skipSet.Contains($_) })
$_skippedNics = @($_allNics | Where-Object {      $_skipSet.Contains($_) })

if ($_testNics.Count -lt 2) {
    Write-Error "Need at least 2 testable Ethernet NICs; found $($_testNics.Count) after exclusions (excluded: $($_skippedNics -join ', '))."
    exit 1
}

# -- Pair NICs: [0]<->[1], [2]<->[3], ... -------------------------------------
$_evenNics  = @()
$_oddNics   = @()
$_unpairedNics = @()
$_pairCount = [Math]::Floor($_testNics.Count / 2)
for ($i = 0; $i -lt $_pairCount; $i++) {
    $_evenNics  += $_testNics[$i * 2]
    $_oddNics   += $_testNics[$i * 2 + 1]
}
if ($_testNics.Count % 2 -eq 1) {
    $_unpairedNics += $_testNics[-1]
    Write-Warning "Odd NIC count -- '$($_testNics[-1])' has no pair and will be skipped (N/A in report)."
}

Write-Host ""
for ($i = 0; $i -lt $_evenNics.Count; $i++) {
    Write-Host ("  Pair $i : " + $_evenNics[$i] + " <-> " + $_oddNics[$i]) -ForegroundColor Green
}
foreach ($u in $_unpairedNics) { Write-Host ("  Unpaired : $u") -ForegroundColor Yellow }
Write-Host ""
Write-Host ("  Loops: $Loops   iperf3 time: ${IperfTimeSec}s   omit: ${IperfOmitSec}s   TCP pass: ${TcpPassPct}%")
Write-Host ""

# -- Test IP helpers (the Windows namespace equivalent) ------------------------
# Per pair i: even -> 192.247.i.1/24   fd00:2470::i:1/64
#             odd  -> 192.247.i.11/24  fd00:2470::i:11/64
# No default gateway is set, so the OS will only use these IPs when explicitly
# bound (--bind / -S), not for general traffic.  This mirrors Linux netns.

function Add-TestIPs {
    param([int]$Idx, [string]$Even, [string]$Odd)
    $v4e = "192.247.$Idx.1";   $v4o = "192.247.$Idx.11"
    $v6e = "fd00:2470::${Idx}:1"; $v6o = "fd00:2470::${Idx}:11"
    foreach ($x in @(@{Alias=$Even;IP=$v4e;PL=24},@{Alias=$Odd;IP=$v4o;PL=24},
                     @{Alias=$Even;IP=$v6e;PL=64},@{Alias=$Odd;IP=$v6o;PL=64})) {
        try { New-NetIPAddress -InterfaceAlias $x.Alias -IPAddress $x.IP `
                -PrefixLength $x.PL -ErrorAction Stop | Out-Null }
        catch { }  # ignore "already exists" errors on re-run
    }
    Write-Host ("  [Pair $Idx] $v4e -> $Even  $v4o -> $Odd") -ForegroundColor DarkGray
}

function Remove-TestIPs {
    param([int]$PairCount)
    for ($i = 0; $i -lt $PairCount; $i++) {
        foreach ($ip in @("192.247.$i.1","192.247.$i.11","fd00:2470::${i}:1","fd00:2470::${i}:11")) {
            Remove-NetIPAddress -IPAddress $ip -Confirm:$false -ErrorAction SilentlyContinue
        }
    }
    Write-Host "  Test IPs removed." -ForegroundColor DarkGray
}

# -- Detect link speeds (before IP assignment, while NICs are in normal state) -
$_pairSpeeds = @()
for ($i = 0; $i -lt $_evenNics.Count; $i++) {
    $spd = 0
    try { $a = Get-NetAdapter -Name $_evenNics[$i] -ErrorAction SilentlyContinue
          if ($null -ne $a) { $spd = [int]($a.LinkSpeed / 1e6) } } catch {}
    if ($spd -le 0) { $spd = 1000 }   # fallback: assume GbE if NIC not linked yet
    $_pairSpeeds += $spd
    Write-Host ("  Pair $i link speed : ${spd} Mbps") -ForegroundColor DarkGray
}

# -- Main log setup ------------------------------------------------------------
$_runTs   = Now-Ts
$_mainLog = Join-Path $_log_path "net_test_$_runTs.log"

function Write-MainLog { param([string]$Msg)
    "[$(Now-Iso)] $Msg" | Add-Content -Path $_mainLog -Encoding UTF8
}

@(
    "============= Network Test ($_runTs) ============="
    "Host: $($env:COMPUTERNAME)   User: $($env:USERNAME)"
    "Loops: $Loops   iperf3 time: ${IperfTimeSec}s   omit: ${IperfOmitSec}s   TCP pass: ${TcpPassPct}%"
    "Mode: parallel pairs ($($_evenNics.Count) pair(s))"
    "======================================================="
) | Out-File -FilePath $_mainLog -Encoding UTF8

# -- Per-pair job scriptblock --------------------------------------------------
# Runs in a separate PS process via Start-Job, so all helpers must be self-
# contained (no access to the calling script's functions or variables).
$_pairJobBlock = {
    param(
        [int]    $PairIdx,
        [string] $EvenNic,
        [string] $OddNic,
        [int]    $SpeedMbps,
        [string] $LogRoot,
        [string] $RunTs,
        [int]    $LoopN,
        [int]    $TotalLoops,
        [int]    $IperfTime,
        [int]    $IperfOmit,
        [int]    $TcpPct,
        [bool]   $Dry
    )

    function Now-Iso { Get-Date -Format 'yyyy-MM-ddTHH:mm:ss' }

    # Invoke iperf3 client and wait.  Writes output to $LogFile via --logfile.
    function Invoke-IperfClient {
        param([string]$ClientIp, [string]$ServerIp, [int]$Port,
              [int]$SpeedM, [int]$TimeSec, [int]$Omit,
              [bool]$Reverse, [bool]$Udp, [string]$LogFile, [bool]$Dry)
        if ($Dry) {
            "DRY-RUN iperf3 client $ClientIp->$ServerIp tcp=$(-not $Udp) rev=$Reverse ${TimeSec}s" |
                Set-Content $LogFile; return
        }
        $a = @('--client',$ServerIp,'--bind',$ClientIp,'--port',$Port,
               '--bitrate',"${SpeedM}M",'--time',$TimeSec,
               '--interval','3','--omit',$Omit,'--logfile',$LogFile,'--forceflush')
        if ($Reverse) { $a += '--reverse' }
        if ($Udp)     { $a += '--udp' }
        $p = Start-Process iperf3 -ArgumentList $a -Wait -PassThru -NoNewWindow -WindowStyle Hidden
        if ($p.ExitCode -ne 0) { "iperf3 client exit $($p.ExitCode)" | Add-Content $LogFile }
    }

    # Start iperf3 server in background; return PID.
    function Start-IperfServer {
        param([string]$BindIp, [int]$Port, [bool]$Dry)
        if ($Dry) { return 0 }
        $p = Start-Process iperf3 -ArgumentList @('--server','--bind',$BindIp,'--port',$Port) `
             -PassThru -NoNewWindow -WindowStyle Hidden
        Start-Sleep -Seconds 1   # wait for server to finish binding
        return $p.Id
    }

    function Stop-IperfServer {
        param([int]$Pid)
        if ($Pid -le 0) { return }
        Stop-Process -Id $Pid -Force -ErrorAction SilentlyContinue
    }

    # Extract the receiver throughput from an iperf3 log file; returns Mbits/sec.
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

    # Ping check using Windows ping.exe exit code (0 = all packets received),
    # locale-independent.
    function Invoke-PingCheck {
        param([string]$SrcIp, [string]$DstIp, [bool]$IsV6, [bool]$Dry)
        if ($Dry) { return 'PASS' }
        $a = @('-n','4','-S',$SrcIp)
        if ($IsV6) { $a += '-6' }
        $a += $DstIp
        & ping @a 2>&1 | Out-Null
        return if ($LASTEXITCODE -eq 0) { 'PASS' } else { 'FAIL' }
    }

    # ---- per-pair test logic -------------------------------------------------
    $pair   = "$EvenNic<->$OddNic"
    $v4even = "192.247.$PairIdx.1";    $v4odd = "192.247.$PairIdx.11"
    $v6even = "fd00:2470::${PairIdx}:1"; $v6odd = "fd00:2470::${PairIdx}:11"
    $port   = 5201   # same port ok - each pair binds to a different IP

    # iperf3 log filename (NET013): iPerf3_<ev>_n_<od>_<n>of<m>_<type>_spd<S>_<ts>.log
    function Get-IperfLog { param([string]$Type)
        Join-Path $LogRoot "iPerf3_${EvenNic}_n_${OddNic}_${LoopN}of${TotalLoops}_${Type}_spd${SpeedMbps}_${RunTs}.log"
    }

    $pairLog = Join-Path $LogRoot "net_test_pair${PairIdx}_${RunTs}.log"
    @(
        "============= Pair ${PairIdx}: ${pair} ============="
        "Start: $(Now-Iso)"
        "Link speed: ${SpeedMbps} Mbps   Iteration: $LoopN/$TotalLoops"
        "TCP pass threshold: $TcpPct% = $([Math]::Round($SpeedMbps * $TcpPct / 100.0,1)) Mbps"
        "====================================================="
    ) | Set-Content $pairLog

    # IPv4 ping
    "[IPv4 ICMP] $v4even -> $v4odd" | Add-Content $pairLog
    $v4Res = Invoke-PingCheck -SrcIp $v4even -DstIp $v4odd -IsV6 $false -Dry $Dry
    "Result: $v4Res" | Add-Content $pairLog

    # IPv6 ping
    "[IPv6 ICMP] $v6even -> $v6odd" | Add-Content $pairLog
    $v6Res = Invoke-PingCheck -SrcIp $v6even -DstIp $v6odd -IsV6 $true -Dry $Dry
    "Result: $v6Res" | Add-Content $pairLog

    # iperf3: one server start/stop per direction (robust across all iperf3 versions)
    $logTcpRev = Get-IperfLog 'TCPRev'
    $logTcpFwd = Get-IperfLog 'TCP'
    $logUdpRev = Get-IperfLog 'UDPRev'
    $logUdpFwd = Get-IperfLog 'UDP'

    "[TCP Reverse] $EvenNic <- $OddNic @ $SpeedMbps Mbps" | Add-Content $pairLog
    $srv = Start-IperfServer -BindIp $v4odd -Port $port -Dry $Dry
    Invoke-IperfClient -ClientIp $v4even -ServerIp $v4odd -Port $port -SpeedM $SpeedMbps `
        -TimeSec $IperfTime -Omit $IperfOmit -Reverse $true -Udp $false -LogFile $logTcpRev -Dry $Dry
    Stop-IperfServer -Pid $srv

    "[TCP Forward] $EvenNic -> $OddNic @ $SpeedMbps Mbps" | Add-Content $pairLog
    $srv = Start-IperfServer -BindIp $v4odd -Port $port -Dry $Dry
    Invoke-IperfClient -ClientIp $v4even -ServerIp $v4odd -Port $port -SpeedM $SpeedMbps `
        -TimeSec $IperfTime -Omit $IperfOmit -Reverse $false -Udp $false -LogFile $logTcpFwd -Dry $Dry
    Stop-IperfServer -Pid $srv

    "[UDP Reverse] $EvenNic <- $OddNic @ $SpeedMbps Mbps" | Add-Content $pairLog
    $srv = Start-IperfServer -BindIp $v4odd -Port $port -Dry $Dry
    Invoke-IperfClient -ClientIp $v4even -ServerIp $v4odd -Port $port -SpeedM $SpeedMbps `
        -TimeSec $IperfTime -Omit $IperfOmit -Reverse $true -Udp $true -LogFile $logUdpRev -Dry $Dry
    Stop-IperfServer -Pid $srv

    "[UDP Forward] $EvenNic -> $OddNic @ $SpeedMbps Mbps" | Add-Content $pairLog
    $srv = Start-IperfServer -BindIp $v4odd -Port $port -Dry $Dry
    Invoke-IperfClient -ClientIp $v4even -ServerIp $v4odd -Port $port -SpeedM $SpeedMbps `
        -TimeSec $IperfTime -Omit $IperfOmit -Reverse $false -Udp $true -LogFile $logUdpFwd -Dry $Dry
    Stop-IperfServer -Pid $srv

    $nTcpFwd = Get-IperfMbps $logTcpFwd
    $nTcpRev = Get-IperfMbps $logTcpRev
    $nUdpFwd = Get-IperfMbps $logUdpFwd
    $nUdpRev = Get-IperfMbps $logUdpRev

    # Verdict (NET009): ping fail -> FAIL; no TCP data -> UNKNOWN; TCP >= thr -> PASS
    $thr = [Math]::Round($SpeedMbps * $TcpPct / 100.0, 2)
    $verdict = if     ($v4Res -ne 'PASS' -or $v6Res -ne 'PASS') { 'FAIL' }
               elseif ($nTcpFwd -eq 0.0 -or $nTcpRev -eq 0.0)  { 'UNKNOWN' }
               elseif ($nTcpFwd -ge $thr -and $nTcpRev -ge $thr){ 'PASS' }
               else                                              { 'FAIL' }

    "Verdict: $verdict  tcpFwd=${nTcpFwd}M  tcpRev=${nTcpRev}M  udpFwd=${nUdpFwd}M  udpRev=${nUdpRev}M  thr=${thr}M" |
        Add-Content $pairLog
    "End: $(Now-Iso)" | Add-Content $pairLog

    return @{
        name   = $pair
        speeds = @(@{
            speed_mbps = $SpeedMbps
            ipv4_ping  = $v4Res
            ipv6_ping  = $v6Res
            throughput = @{
                tcp_fwd_mbps = $nTcpFwd; tcp_rev_mbps = $nTcpRev
                udp_fwd_mbps = $nUdpFwd; udp_rev_mbps = $nUdpRev
            }
            verdict = $verdict
        })
        error = ''
    }
}

# -- Main run loop -------------------------------------------------------------
# Collect per-pair data across all loops, keyed by pair name.
$_pairResults = @{}   # name -> @{ name; speeds=[] }

try {
    if (-not $DryRun) {
        Write-Host "Assigning test IPs..." -ForegroundColor Cyan
        for ($i = 0; $i -lt $_evenNics.Count; $i++) {
            Add-TestIPs -Idx $i -Even $_evenNics[$i] -Odd $_oddNics[$i]
        }
        Start-Sleep -Seconds 3   # allow OS to finish address configuration + NDP
        Write-Host ""
    }

    for ($loop = 1; $loop -le $Loops; $loop++) {
        Write-Host "--- Loop $loop / $Loops ---" -ForegroundColor Cyan
        Write-MainLog "=== Loop $loop/$Loops START - $($_evenNics.Count) pair(s) ==="

        # Launch all pairs in parallel (NET010)
        $jobs = @()
        for ($i = 0; $i -lt $_evenNics.Count; $i++) {
            $j = Start-Job -ScriptBlock $_pairJobBlock -ArgumentList @(
                $i, $_evenNics[$i], $_oddNics[$i], $_pairSpeeds[$i],
                $_log_path, $_runTs, $loop, $Loops,
                $IperfTimeSec, $IperfOmitSec, $TcpPassPct, ([bool]$DryRun)
            )
            Write-Host "  [Pair $i] Job $($j.Id) started  ($_evenNics[$i] <-> $_oddNics[$i])"
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
                    $verd = if ($res.speeds.Count -gt 0) { $res.speeds[-1].verdict } else { '?' }
                    Write-MainLog "[Pair] DONE  $($res.name)  verdict=$verd"
                    Write-Host ("  [Pair] " + $res.name + "  verdict=$verd") `
                        -ForegroundColor (if ($verd -eq 'PASS') {'Green'} elseif ($verd -eq 'FAIL') {'Red'} else {'Yellow'})
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
    if (-not $DryRun) {
        Write-Host "`nRemoving test IPs..." -ForegroundColor Cyan
        Remove-TestIPs -PairCount $_evenNics.Count
    }
}

# -- Assemble full pairs list for result.json ----------------------------------
$_allPairs = @([array]$_pairResults.Values)

# N/A rows for unpaired NICs (NET010 odd-count handling)
foreach ($u in $_unpairedNics) {
    $_allPairs += @{
        name        = $u
        skip_reason = 'no pair (odd NIC count)'
        speeds      = @(@{ speed_mbps=0; ipv4_ping='N/A'; ipv6_ping='N/A'
                           throughput=@{tcp_fwd_mbps=0;tcp_rev_mbps=0;udp_fwd_mbps=0;udp_rev_mbps=0}
                           verdict='N/A' })
    }
}

# SKIPPED rows for NICs excluded via -Skip (NET011)
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
$_pass    = @($_allSpeedItems | Where-Object { $_.verdict -eq 'PASS'              }).Count
$_fail    = @($_allSpeedItems | Where-Object { $_.verdict -eq 'FAIL'              }).Count
$_unknown = @($_allSpeedItems | Where-Object { $_.verdict -eq 'UNKNOWN'           }).Count
$_skipped = @($_allSpeedItems | Where-Object { $_.verdict -in @('SKIPPED','N/A')  }).Count

$_verdict = if   ($_fail -gt 0)                              { 'FAIL' }
            elseif ($_pass -eq ($_total - $_skipped) -and ($_total - $_skipped) -gt 0) { 'PASS' }
            else                                             { 'UNKNOWN' }

$_result = [ordered]@{
    schema_version  = '1.1'
    test_name       = 'net_test'
    test_version    = $_script_ver
    session_id      = $_runTs
    started_at      = $_runTs
    ended_at        = (Now-Iso)
    config          = [ordered]@{
        dut_host       = $env:COMPUTERNAME
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
Write-Utf8NoBom -Path $_resultFile -Text ($_result | ConvertTo-Json -Depth 8)

Write-Host ""
Write-Host "[INFO] Main log    : $_mainLog"    -ForegroundColor Cyan
Write-Host "[INFO] Result JSON : $_resultFile" -ForegroundColor Cyan
$_col = if ($_verdict -eq 'PASS') {'Green'} elseif ($_verdict -eq 'FAIL') {'Red'} else {'Yellow'}
Write-Host "[INFO] Overall     : $_verdict  (pass=$_pass fail=$_fail unknown=$_unknown skipped=$_skipped)" -ForegroundColor $_col
