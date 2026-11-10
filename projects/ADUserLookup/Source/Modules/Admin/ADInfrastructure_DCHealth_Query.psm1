#region -- ADInfrastructure.DCHealth.Query.psm1 -------------------------------
# Concern : Get-DCHealth - pings every DC, checks SYSVOL/NETLOGON shares,
#           measures time drift via w32tm, and checks replication via repadmin.
# Load order: 101 - depends on ADInfrastructure.RichText.Header (script scope)
# Split from: ADInfrastructure.Query.psm1
#endregion

#region -- Get-DCHealth -------------------------------------------------------
function Get-DCHealth {
    $srv     = $script:InfraCtx.TargetDC
    $results = [System.Collections.Generic.List[PSCustomObject]]::new()
    try {
        $dcs = Get-ADDomainController -Filter * -Server $srv -ErrorAction Stop | Sort-Object Name
        foreach ($dc in $dcs) {
            $h        = $dc.HostName
            $ping     = if (Test-Connection -ComputerName $h -Count 1 -Quiet -ErrorAction SilentlyContinue) { 'OK' } else { 'FAIL' }
            $sysvol   = 'FAIL'; $netlogon = 'FAIL'; $timeDrift = '?'; $replOK = 'FAIL'
            if ($ping -eq 'OK') {
                $sysvol   = if (Test-Path "\\$h\SYSVOL"  -ErrorAction SilentlyContinue) { 'OK' } else { 'FAIL' }
                $netlogon = if (Test-Path "\\$h\NETLOGON" -ErrorAction SilentlyContinue) { 'OK' } else { 'FAIL' }
                try {
                    $w32 = (& w32tm /stripchart /computer:$h /samples:1 /dataonly 2>$null) | Select-Object -Last 1
                    $timeDrift = if ($w32 -match '[+-][\d\.]+s') { $Matches[0] } else { 'OK' }
                } catch { $timeDrift = 'N/A' }
                try {
                    $replOut  = (& repadmin /showrepl $h /csv 2>$null)
                    $replFail = $replOut | Where-Object { $_ -match 'Last Failure' -and $_ -notmatch ',0,' }
                    $replOK   = if ($replFail) { 'WARN' } else { 'OK' }
                } catch { $replOK = 'N/A' }
            }
            $results.Add([PSCustomObject]@{
                DCName        = $dc.Name
                Site          = $dc.Site
                IsGC          = [string]$dc.IsGlobalCatalog
                IsPDC         = [string]$dc.OperationMasterRoles.Contains('PDCEmulator')
                Ping          = $ping
                SYSVOL        = $sysvol
                NETLOGON      = $netlogon
                TimeDrift     = $timeDrift
                ReplicationOK = $replOK
                OS            = $dc.OperatingSystem
            })
        }
    } catch { }
    return $results
}
#endregion

Export-ModuleMember -Function Get-DCHealth
