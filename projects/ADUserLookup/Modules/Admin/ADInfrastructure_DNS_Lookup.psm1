#region -- ADInfrastructure.DNS.Lookup.psm1 -----------------------------------
# Concern : Invoke-DNSLookup - resolves DNS queries using Resolve-DnsName
#           (RSAT DNS preferred) with .NET GetHostEntry/GetHostAddresses fallback.
#           Populates DNSGrid directly.
# Load order: 105 - depends on ADInfrastructure.RichText.Header (script scope),
#                             Services.AD.Reporting (Set-GridData)
# Split from: ADInfrastructure.Query.psm1
#endregion

#region -- Invoke-DNSLookup ---------------------------------------------------
function Invoke-DNSLookup {
    param([string]$Query, [string]$Type = 'A', [string]$Server = '')
    $results = [System.Collections.Generic.List[PSCustomObject]]::new()
    $srv     = if ($Server) { $Server } else { $script:InfraCtx.TargetDC }
    $isIP    = $Query -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$'
    if ($isIP) { $Type = 'PTR' }
    try {
        if ($isIP) {
            $hostEntry = [System.Net.Dns]::GetHostEntry($Query)
            $results.Add([PSCustomObject]@{ Name=$Query; Type='PTR'; Value=$hostEntry.HostName; TTL=''; Server=$srv })
        } elseif (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue) {
            $params = @{ Name=$Query; ErrorAction='Stop' }
            if ($srv)            { $params.Server = $srv }
            if ($Type -ne 'All') { $params.Type   = $Type }
            $records = Resolve-DnsName @params
            foreach ($r in $records) {
                $value = switch ($r.Type) {
                    'A'     { $r.IPAddress }
                    'AAAA'  { $r.IPAddress }
                    'CNAME' { $r.NameHost }
                    'MX'    { "$($r.NameExchange) (pref $($r.Preference))" }
                    'NS'    { $r.NameHost }
                    'PTR'   { $r.NameHost }
                    'SOA'   { "$($r.PrimaryServer) / $($r.Administrator)" }
                    'SRV'   { "$($r.NameTarget):$($r.Port) (pri $($r.Priority))" }
                    'TXT'   { $r.Strings -join ' ' }
                    default { $r.ToString() }
                }
                $results.Add([PSCustomObject]@{ Name=$r.Name; Type=[string]$r.Type; Value=$value; TTL=[string]$r.TTL; Server=$srv })
            }
        } else {
            $hostEntry = [System.Net.Dns]::GetHostAddresses($Query)
            foreach ($addr in $hostEntry) {
                $results.Add([PSCustomObject]@{ Name=$Query; Type=$addr.AddressFamily; Value=$addr.IPAddressToString; TTL=''; Server='System DNS' })
            }
        }
    } catch {
        $results.Add([PSCustomObject]@{ Name=$Query; Type=$Type; Value="ERROR: $($_.Exception.Message)"; TTL=''; Server=$srv })
    }
    $cols = @('Name','Type','Value','TTL','Server')
    Set-GridData -Grid $script:DNSGrid -Data $results -Columns $cols
    Set-Status "DNS lookup: $($results.Count) record(s) for $Query" 'ok'
}
#endregion

Export-ModuleMember -Function Invoke-DNSLookup
