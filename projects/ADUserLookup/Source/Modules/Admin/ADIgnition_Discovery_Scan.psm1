#region -- ADIgnition.Discovery.Scan.psm1 ---------------------------------------
# Concern : Low-noise Ignition gateway discovery engine - no UI.
#             Get-IgnitionCachePath      - cache file under the data root's Settings
#             Save-IgnitionCache / Load-IgnitionCache
#             Invoke-IgnitionDiscovery   - probe each computer's Ignition gateway
#                                          over HTTP and return one record each.
#
# ALERT POSTURE (why this is written the way it is)
# -------------------------------------------------
# The old standalone scanner (ControlSystemsConnect.ps1) found gateways by
# opening TCP 445 to every server and then walking its C$/D$/E$/F$ ADMIN SHARES
# (Test-Path \\host\c$\...\data\projects, Get-ChildItem over SMB) to read the
# project folders. Sweeping admin shares across the whole server estate is a
# classic lateral-movement / recon signature and is exactly what an EDR or SOC
# alerts on.
#
# This engine does NONE of that. For each host it makes ONE HTTP GET to the
# gateway's own information endpoint - /system/gwinfo on the Ignition web port
# (8088 http, then 8043 https) - the very endpoint the Inductive Automation
# launchers themselves call. That is ordinary application traffic to a known
# service port, not file-share reconnaissance. Consequences of the trade-off:
#   - No SMB, no port 445, no admin-share access, no filesystem walk.
#   - We learn the gateway (name, version, edition, role, redundancy, up/down),
#     NOT the per-project folder list - that detail required reading the disk.
# Keep concurrency modest (default 8) and the per-request timeout short so the
# pass looks like health polling, not a fast port sweep.
#
# Load order: before ADIgnition.Register-DiscoveryTab, which hosts the tab that
#             calls these. Depends on Services.AD.Connection.Query
#             (Get-DomainComputers), AD_Core (Set-Status), Base\Services_Settings
#             (Get-AppSettingsDir).
# Notes     : PS 5.1 compatible - no ternary, no ?? , no -Parallel foreach.
#endregion

#region -- Module config --------------------------------------------------------
$script:IgnHttpPort  = 8088
$script:IgnHttpsPort = 8043
$script:IgnInfoPath  = '/system/gwinfo'
#endregion

#region -- Cache ----------------------------------------------------------------
function Get-IgnitionCachePath {
    if (Get-Command Get-AppSettingsDir -ErrorAction SilentlyContinue) {
        try { return (Join-Path (Get-AppSettingsDir -App $script:ADApp) 'ignition-gateways.json') } catch { }
    }
    return (Join-Path $env:TEMP 'ignition-gateways.json')
}

function Save-IgnitionCache {
    param([object]$Data)
    try {
        $wrapper = [ordered]@{ ScannedAt = (Get-Date).ToUniversalTime().ToString('o'); Gateways = @($Data) }
        $wrapper | ConvertTo-Json -Depth 6 | Set-Content -Path (Get-IgnitionCachePath) -Encoding UTF8
    } catch {
        if (Get-Command Set-Status -ErrorAction SilentlyContinue) { Set-Status "Could not save Ignition cache: $($_.Exception.Message)" 'warn' }
    }
}

function Load-IgnitionCache {
    # Returns @{ Data = <list>; ScannedAt = <datetime|null> } or $null.
    $p = Get-IgnitionCachePath
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try {
        $w = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
        $list = New-Object System.Collections.Generic.List[PSCustomObject]
        foreach ($g in @($w.Gateways)) { [void]$list.Add([PSCustomObject]$g) }
        $when = $null
        if ($w.ScannedAt) { try { $when = [datetime]::Parse($w.ScannedAt) } catch { } }
        return @{ Data = $list; ScannedAt = $when }
    } catch { return $null }
}
#endregion

#region -- Scan scriptblock (self-contained, runs in a runspace) ----------------
# ONE HTTP GET of the gateway info endpoint. No SMB, no filesystem, no ports
# other than the Ignition web port. Returns exactly one hashtable per host.
$script:IgnProbeBlock = {
    param([string]$Name, [string]$Dns, [string]$Ip, [int]$HttpPort, [int]$HttpsPort, [string]$InfoPath, [int]$TimeoutMs)

    $target = if ($Dns) { $Dns } elseif ($Ip) { $Ip } else { $Name }

    function Get-GwInfo {
        param([string]$Url, [int]$ToMs)
        $cbSet = $false
        try {
            # Accept self-signed certs for THIS probe only (gateway certs are
            # often internal); restored in finally so the process default stands.
            [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
            $cbSet = $true
            $req = [System.Net.HttpWebRequest]::Create($Url)
            $req.Method    = 'GET'
            $req.Timeout   = $ToMs
            $req.ReadWriteTimeout = $ToMs
            $req.UserAgent = 'IgnitionGatewayDiscovery'
            $req.AllowAutoRedirect = $true
            $resp = $req.GetResponse()
            try {
                $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
                $body = $sr.ReadToEnd()
                $sr.Close()
            } finally { $resp.Close() }
            return $body
        } catch {
            return $null
        } finally {
            if ($cbSet) { [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $null }
        }
    }

    $scheme = ''
    $body = Get-GwInfo "http://${target}:$HttpPort$InfoPath" $TimeoutMs
    if ($null -ne $body) { $scheme = 'http' }
    if ($null -eq $body) {
        $body = Get-GwInfo "https://${target}:$HttpsPort$InfoPath" $TimeoutMs
        if ($null -ne $body) { $scheme = 'https' }
    }

    if ($null -eq $body) {
        Write-Output @{
            Name = $Name; DNS = $Dns; IP = $Ip; Reachable = $false; IsIgnition = $false
            Version = ''; Edition = ''; GatewayName = ''; Role = ''; Redundancy = ''; Scheme = ''
        }
        return
    }

    # Parse gwinfo. Format varies by Ignition version (JSON-ish or key=value),
    # so pull fields defensively with regexes rather than assuming a shape.
    $version = ''; $edition = ''; $gwName = ''; $role = ''; $redun = ''
    $m = [regex]::Match($body, '(?i)"?version"?\s*[:=]\s*"?\s*([0-9]+\.[0-9]+\.[0-9]+[^",}\s]*)')
    if (-not $m.Success) { $m = [regex]::Match($body, '([0-9]+\.[0-9]+\.[0-9]+)') }
    if ($m.Success) { $version = $m.Groups[1].Value }
    $m = [regex]::Match($body, '(?i)"?edition"?\s*[:=]\s*"?([A-Za-z ]+)')
    if ($m.Success) { $edition = $m.Groups[1].Value.Trim() }
    $m = [regex]::Match($body, '(?i)"?(?:gatewayName|name)"?\s*[:=]\s*"?([^",}\r\n]+)')
    if ($m.Success) { $gwName = $m.Groups[1].Value.Trim() }
    $m = [regex]::Match($body, '(?i)"?(?:nodeRole|role)"?\s*[:=]\s*"?([A-Za-z]+)')
    if ($m.Success) { $role = $m.Groups[1].Value.Trim() }
    $m = [regex]::Match($body, '(?i)"?(?:redundancyRole|redundancy|redundancyState)"?\s*[:=]\s*"?([A-Za-z]+)')
    if ($m.Success) { $redun = $m.Groups[1].Value.Trim() }

    Write-Output @{
        Name = $Name; DNS = $Dns; IP = $Ip; Reachable = $true; IsIgnition = $true
        Version = $version; Edition = $edition; GatewayName = $gwName
        Role = $role; Redundancy = $redun; Scheme = $scheme
    }
}
#endregion

#region -- Invoke-IgnitionDiscovery ---------------------------------------------
function Invoke-IgnitionDiscovery {
    <#
    .SYNOPSIS
        Probes each supplied computer's Ignition gateway over HTTP (gwinfo
        endpoint) and returns one record per host. Servers-only by default.
    .OUTPUTS
        List of PSCustomObject (Name, DNS, IP, Reachable, IsIgnition, Version,
        Edition, GatewayName, Role, Redundancy, Scheme). Saved to cache.
    #>
    param(
        [object]                                     $Computers,
        [int]                                        $ThreadCount = 8,
        [int]                                        $TimeoutMs   = 2500,
        [bool]                                       $ServersOnly = $true,
        [System.Windows.Forms.ToolStripStatusLabel]  $StatusLabel,
        [System.Windows.Forms.ProgressBar]           $ProgressBar
    )

    $list = @($Computers)
    if ($ServersOnly) { $list = @($list | Where-Object { [string]$_.OperatingSystem -like '*Server*' }) }
    $total = $list.Count

    $setText = { param($t) if ($StatusLabel) { $StatusLabel.Text = $t; [System.Windows.Forms.Application]::DoEvents() } }
    & $setText "Ignition discovery: probing $total host(s) with $ThreadCount threads (HTTP only)..."
    if ($ProgressBar) { $ProgressBar.Maximum = [math]::Max($total, 1); $ProgressBar.Value = 0 }

    $pool = [RunspaceFactory]::CreateRunspacePool(1, [math]::Max(1, $ThreadCount))
    $pool.Open()

    $jobs = New-Object System.Collections.Generic.List[hashtable]
    foreach ($comp in $list) {
        $dns = [string]$comp.DNSHostName
        $ip  = [string]$comp.IPv4Address
        $ps  = [PowerShell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript($script:IgnProbeBlock)
        [void]$ps.AddArgument([string]$comp.Name)
        [void]$ps.AddArgument($dns)
        [void]$ps.AddArgument($ip)
        [void]$ps.AddArgument($script:IgnHttpPort)
        [void]$ps.AddArgument($script:IgnHttpsPort)
        [void]$ps.AddArgument($script:IgnInfoPath)
        [void]$ps.AddArgument($TimeoutMs)
        $jobs.Add(@{ PS = $ps; Handle = $ps.BeginInvoke(); Name = [string]$comp.Name })
    }

    $out       = New-Object System.Collections.Generic.List[PSCustomObject]
    $completed = 0
    while ($completed -lt $jobs.Count) {
        Start-Sleep -Milliseconds 150
        [System.Windows.Forms.Application]::DoEvents()
        foreach ($job in $jobs) {
            if ($null -eq $job.Handle) { continue }
            if ($job.Handle.IsCompleted) {
                $completed++
                if ($ProgressBar) { $ProgressBar.Value = [math]::Min($completed, $ProgressBar.Maximum) }
                & $setText "Ignition discovery: $completed / $($jobs.Count) complete"
                try {
                    foreach ($r in $job.PS.EndInvoke($job.Handle)) {
                        if ($r -is [hashtable]) { [void]$out.Add([PSCustomObject]$r) }
                    }
                } catch { }
                $job.PS.Dispose()
                $job.Handle = $null
            }
        }
    }
    $pool.Close(); $pool.Dispose()
    if ($ProgressBar) { $ProgressBar.Value = 0 }

    $gateways = @($out | Where-Object { $_.IsIgnition } | Sort-Object Name)
    & $setText "Ignition discovery complete: $($gateways.Count) gateway(s) of $total host(s) probed."
    Save-IgnitionCache -Data $gateways
    return (, $gateways)
}
#endregion

Export-ModuleMember -Function `
    Get-IgnitionCachePath, Save-IgnitionCache, Load-IgnitionCache, Invoke-IgnitionDiscovery
