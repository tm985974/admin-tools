#region -- ADInfrastructure.GPO.Scope.psm1 ------------------------------------
# Concern : Invoke-GPOScope - walks the OU chain from the given DN upward,
#           collecting GPO links at each level via Get-GPInheritance.
#           Populates GPOGrid and stores data in $script:GPOData for export.
# Load order: 109 - depends on ADInfrastructure.RichText.Header (script scope),
#                             Services.AD.Reporting (Set-GridData, Write-OperationLog)
# Split from: ADInfrastructure.Query.psm1
#endregion

#region -- Invoke-GPOScope ----------------------------------------------------
function Invoke-GPOScope {
    param([string]$OUDN)
    $results   = [System.Collections.Generic.List[PSCustomObject]]::new()
    $srv       = $script:InfraCtx.TargetDC
    $currentDN = $OUDN
    try {
        while ($currentDN) {
            try {
                $ou    = Get-ADOrganizationalUnit -Identity $currentDN -Properties gpLink -Server $srv -ErrorAction Stop
                $links = Get-GPInheritance -Target $currentDN -Server $srv -ErrorAction Stop
                foreach ($link in $links.GpoLinks) {
                    $gpo = try { Get-GPO -Guid $link.GpoId -Server $srv -ErrorAction Stop } catch { $null }
                    $results.Add([PSCustomObject]@{
                        LinkedOU = $currentDN
                        GPOName  = $link.DisplayName
                        GPOID    = [string]$link.GpoId
                        Enabled  = [string]$link.Enabled
                        Enforced = [string]$link.Enforced
                        Order    = [string]$link.Order
                        Status   = if ($gpo) { [string]$gpo.GpoStatus } else { 'Unknown' }
                        Modified = if ($gpo -and $gpo.ModificationTime) { $gpo.ModificationTime.ToString('yyyy-MM-dd') } else { '' }
                    })
                }
            } catch { }

            if ($currentDN -match '^[^,]+,(.+)$') { $currentDN = $Matches[1] }
            else { break }
            if ($currentDN -notmatch '^OU=') { break }
        }

        $script:GPOData = $results
        $cols = @('LinkedOU','GPOName','Enabled','Enforced','Order','Status','Modified','GPOID')
        Set-GridData -Grid $script:GPOGrid -Data $results -Columns $cols

        foreach ($row in $script:GPOGrid.Rows) {
            if ($row.Cells['Enabled'].Value -eq 'False') {
                $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::DimGray
            }
            if ($row.Cells['Enforced'].Value -eq 'True') {
                $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(220,235,255)
            }
        }
        Set-Status "GPO scope: $($results.Count) link(s) found for OU chain." 'ok'
        Write-OperationLog -Context $script:InfraCtx -Action 'GPO-SCOPE' -Target $OUDN `
            -Result 'OK' -Detail "$($results.Count) GPO links"
    } catch {
        Set-Status "GPO scope failed: $($_.Exception.Message)" 'err'
    }
}
#endregion

Export-ModuleMember -Function Invoke-GPOScope
