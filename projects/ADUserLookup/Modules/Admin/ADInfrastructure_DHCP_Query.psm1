#region -- ADInfrastructure.DHCP.Query.psm1 -----------------------------------
# Concern : Invoke-DHCPLeases - loads DHCP leases from all scopes on the
#           specified DHCP server using the DhcpServer RSAT module.
#           Populates DHCPGrid and stores data in $script:DHCPData for filtering.
# Load order: 107 - depends on ADInfrastructure.RichText.Header (script scope),
#                             Services.AD.Reporting (Set-GridData, Write-OperationLog)
# Split from: ADInfrastructure.Query.psm1
#endregion

#region -- Invoke-DHCPLeases --------------------------------------------------
function Invoke-DHCPLeases {
    $dhcpSrv = $script:DHCPTbSrv.Text.Trim()
    if (-not $dhcpSrv) { Set-Status 'Enter a DHCP server name.' 'warn'; return }
    if (-not (Get-Module -ListAvailable -Name DhcpServer -ErrorAction SilentlyContinue)) {
        Set-Status 'RSAT DHCP Tools (DhcpServer module) not installed.' 'warn'; return
    }
    try {
        Import-Module DhcpServer -ErrorAction Stop
        Set-Status "Loading DHCP scopes from $dhcpSrv ..."
        $scopes  = Get-DhcpServerv4Scope -ComputerName $dhcpSrv -ErrorAction Stop
        $results = [System.Collections.Generic.List[PSCustomObject]]::new()
        foreach ($scope in $scopes) {
            try {
                $leases = Get-DhcpServerv4Lease -ComputerName $dhcpSrv -ScopeId $scope.ScopeId -ErrorAction Stop
                foreach ($l in $leases) {
                    $results.Add([PSCustomObject]@{
                        IPAddress    = [string]$l.IPAddress
                        ClientId     = [string]$l.ClientId
                        HostName     = [string]$l.HostName
                        LeaseExpiry  = if ($l.LeaseExpiryTime) { $l.LeaseExpiryTime.ToString('yyyy-MM-dd HH:mm') } else { 'Infinite' }
                        Scope        = "$($scope.ScopeId) ($($scope.Name))"
                        AddressState = [string]$l.AddressState
                    })
                }
            } catch { }
        }
        $script:DHCPData = $results
        $cols = @('IPAddress','ClientId','HostName','LeaseExpiry','Scope','AddressState')
        Set-GridData -Grid $script:DHCPGrid -Data $results -Columns $cols
        Set-Status "DHCP: $($results.Count) lease(s) loaded from $($scopes.Count) scope(s)." 'ok'
        Write-OperationLog -Context $script:InfraCtx -Action 'DHCP-LEASES' -Target $dhcpSrv `
            -Result 'OK' -Detail "$($results.Count) leases across $($scopes.Count) scopes"
    } catch {
        Set-Status "DHCP lookup failed: $($_.Exception.Message)" 'err'
    }
}
#endregion

Export-ModuleMember -Function Invoke-DHCPLeases
