#region -- ADInfrastructure.Trusts.Query.psm1 ---------------------------------
# Concern : Get-TrustInventory - enumerates all AD trust relationships for the
#           current domain via Get-ADTrust.
# Load order: 103 - depends on ADInfrastructure.RichText.Header (script scope)
# Split from: ADInfrastructure.Query.psm1
#endregion

#region -- Get-TrustInventory -------------------------------------------------
function Get-TrustInventory {
    $srv     = $script:InfraCtx.TargetDC
    $results = [System.Collections.Generic.List[PSCustomObject]]::new()
    try {
        $trusts = Get-ADTrust -Filter * -Server $srv -ErrorAction Stop
        foreach ($t in $trusts) {
            $results.Add([PSCustomObject]@{
                SourceDomain    = $script:InfraCtx.Domain
                TargetDomain    = $t.Target
                TrustType       = [string]$t.TrustType
                TrustDirection  = [string]$t.Direction
                TrustAttributes = [string]$t.TrustAttributes
                Created         = if ($t.Created)  { $t.Created.ToString('yyyy-MM-dd')  } else { '' }
                Modified        = if ($t.Modified) { $t.Modified.ToString('yyyy-MM-dd') } else { '' }
            })
        }
    } catch { }
    return $results | Sort-Object TargetDomain
}
#endregion

Export-ModuleMember -Function Get-TrustInventory
