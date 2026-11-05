#region -- ADTools.SetDns.Engine.psm1 -------------------------------------------
# Concern : Remote DNS client configuration engine - no UI.
#             Get-SetDnsCommandText  - the exact PowerShell one computer's DNS
#                                      change runs (shown / copied via the
#                                      command engine, Base\Services_Commands).
#             Invoke-SetRemoteDns    - set the DNS servers (and optional dynamic
#                                      registration) on each named computer and
#                                      write one OK/FAIL line per computer to the
#                                      shared Activity Log (Write-OperationLog).
# Load order: before ADTools.Register-ToolsTab (126), which hosts the Set DNS
#             sub-tab that calls these. Depends on Services.ADLogging
#             (Write-OperationLog).
# Method    : Invoke-Command (WS-Management / WinRM) running the in-box
#             Set-DnsClientServerAddress / Set-DnsClient cmdlets on the target.
#             Deliberately NOT remote WMI / Win32_NetworkAdapterConfiguration
#             over DCOM (what the old standalone RemoteDNSChange.ps1 used):
#             remote DCOM/WMI is a common lateral-movement signature that an
#             EDR flags, whereas a WinRM session running a management cmdlet is
#             ordinary administration traffic. Requires WinRM enabled on the
#             target and admin rights (same rights the old tool needed).
# Notes     : PS 5.1 compatible - no ternary, no ?? , no -Parallel foreach.
#endregion

#region -- Get-SetDnsCommandText ------------------------------------------------
function Get-SetDnsCommandText {
    <#
    .SYNOPSIS
        The exact PowerShell that Invoke-SetRemoteDns runs on ONE computer, with
        the real values filled in. Runs as-is in a PS 5.1 window.
    #>
    param(
        [string[]] $Names,
        [string[]] $Dns,
        [bool]     $RegisterDynamic = $true
    )
    $fmt = ${function:Format-AppCommandValue}
    if ($fmt) {
        $nameList = & $fmt @($Names)
        $dnsList  = & $fmt @($Dns)
        $regLit   = & $fmt $RegisterDynamic
    } else {
        $nameList = "@('" + (($Names | ForEach-Object { $_.Replace("'", "''") }) -join "', '") + "')"
        $dnsList  = "@('" + (($Dns   | ForEach-Object { $_.Replace("'", "''") }) -join "', '") + "')"
        $regLit   = if ($RegisterDynamic) { '$true' } else { '$false' }
    }

    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add("`$dns = $dnsList")
    [void]$lines.Add("foreach (`$computer in $nameList) {")
    [void]$lines.Add('    Invoke-Command -ComputerName $computer -ScriptBlock {')
    [void]$lines.Add('        param($dns, $register)')
    [void]$lines.Add('        # Every physical adapter that is currently Up (IPv4).')
    [void]$lines.Add('        $nics = Get-NetAdapter -Physical | Where-Object { $_.Status -eq ''Up'' }')
    [void]$lines.Add('        $nics | Set-DnsClientServerAddress -ServerAddresses $dns')
    [void]$lines.Add('        $nics | Set-DnsClient -RegisterThisConnectionsAddress $register')
    [void]$lines.Add("    } -ArgumentList `$dns, $regLit")
    [void]$lines.Add('}')
    return ($lines -join "`r`n")
}
#endregion

#region -- Invoke-SetRemoteDns --------------------------------------------------
function Invoke-SetRemoteDns {
    <#
    .SYNOPSIS
        Sets the IPv4 DNS servers (and optional dynamic-registration flag) on
        every physical "Up" adapter of each named computer, over WinRM. Writes
        one OK/FAIL line per computer to the Activity Log.
    .OUTPUTS
        PSCustomObject: OkCount, FailCount, Results (Name, Success, Message).
    #>
    param(
        [string[]]      $Names,
        [string[]]      $Dns,
        [bool]          $RegisterDynamic = $true,
        [PSCustomObject] $Context
    )
    $names = @($Names | Where-Object { $_ } | Select-Object -Unique)
    $dns   = @($Dns   | Where-Object { $_ })
    if ($names.Count -eq 0 -or $dns.Count -eq 0) { return $null }

    $logFn    = ${function:Write-OperationLog}
    $statusFn = ${function:Set-Status}
    $results  = New-Object System.Collections.Generic.List[PSObject]
    $ok = 0; $fail = 0

    $sb = {
        param($dnsServers, $register)
        $nics = Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' }
        if (-not $nics) { throw 'No physical adapter is Up.' }
        $nics | Set-DnsClientServerAddress -ServerAddresses $dnsServers -ErrorAction Stop
        $nics | Set-DnsClient -RegisterThisConnectionsAddress $register -ErrorAction SilentlyContinue
        return (@($nics | ForEach-Object { $_.Name }) -join ', ')
    }

    $i = 0
    foreach ($name in $names) {
        $i++
        if ($statusFn) { & $statusFn "Setting DNS on $name ($i of $($names.Count))..." 'info' }
        $success = $false; $msg = ''
        try {
            # Two positional args: the DNS array lands whole in $dnsServers
            # (the top-level comma already wraps both args, so the array is not
            # splatted across params), the bool in $register.
            $adapters = Invoke-Command -ComputerName $name -ScriptBlock $sb `
                            -ArgumentList $dns, $RegisterDynamic -ErrorAction Stop
            $success = $true
            $msg = "DNS set on: $adapters"
        } catch {
            $msg = $_.Exception.Message
        }

        if ($success) { $ok++ } else { $fail++ }
        [void]$results.Add([PSCustomObject]@{ Name = $name; Success = $success; Message = $msg })

        if ($logFn) {
            $result = if ($success) { 'OK' } else { 'FAIL' }
            $detail = "DNS: $($dns -join ', ') | Register: $RegisterDynamic | $msg"
            & $logFn -Context $Context -Action 'SET DNS' -Target $name -Result $result -Detail $detail
        }
    }

    if ($statusFn) {
        $lvl = if ($fail -gt 0) { 'warn' } else { 'ok' }
        & $statusFn "DNS set complete. OK: $ok  Failed: $fail" $lvl
    }
    return [PSCustomObject]@{ OkCount = $ok; FailCount = $fail; Results = $results }
}
#endregion

Export-ModuleMember -Function Get-SetDnsCommandText, Invoke-SetRemoteDns
