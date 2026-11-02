#region -- ADAudit.ListReports.Query.Groups.psm1 ------------------------------
# Concern : One read-only audit query against AD group objects, populating
#           the Empty Groups grid on the Audit tab. Self-contained the same
#           way as ADAudit.ListReports.Query.Users/Computers.
# Load order: depends on ADAudit.Register-AuditTab (script scope: $script:AudCtx,
#                        $script:AudGrids),
#                        Services.AD.Connection.Query (Get-OUFromDN),
#                        Services.AD.Reporting (Set-GridData, Write-OperationLog)
# Split from: (new module)
# Performance note: Get-ADGroup has no server-side "member count" filter -
#             determining Members.Count requires reading the full member
#             list for every group in the domain. In a very large domain
#             (many thousands of groups) this single query is the heaviest
#             of the ten Audit tab reports. Same class of cost as
#             ADInfrastructure.PrivAudit.Query's multiple recursive
#             Get-ADGroupMember calls - not a bug, just an inherent cost of
#             the report, called out here so it isn't mistaken for one.
#endregion

#region -- Invoke-EmptyGroupsAudit ------------------------------------------------
function Invoke-EmptyGroupsAudit {
    <#
    .SYNOPSIS
        Every group in the domain with zero members - cleanup candidates.
        Deliberately strict (zero, not "0-1") so the list stays focused on
        groups that are doing nothing at all, rather than every small
        group, most of which are perfectly legitimate.
    #>
    if (-not $script:AudGrids -or -not $script:AudGrids['emptygrp']) { return }
    $srvParam = if ($script:AudCtx -and $script:AudCtx.TargetDC) { @{ Server = $script:AudCtx.TargetDC } } else { @{} }
    $rows     = [System.Collections.Generic.List[PSCustomObject]]::new()

    try {
        $groups = Get-ADGroup -Filter * `
                    -Properties Members, GroupCategory, GroupScope, DistinguishedName `
                    @srvParam -ErrorAction Stop |
                  Where-Object { -not $_.Members -or $_.Members.Count -eq 0 }

        foreach ($g in $groups) {
            $rows.Add([PSCustomObject]@{
                Name          = $g.Name
                GroupCategory = [string]$g.GroupCategory
                GroupScope    = [string]$g.GroupScope
                OU            = if (Get-Command Get-OUFromDN -ErrorAction SilentlyContinue) { Get-OUFromDN -DN $g.DistinguishedName } else { '' }
            })
        }
        if (Get-Command Set-Status -ErrorAction SilentlyContinue) {
            Set-Status "Empty groups audit: $($rows.Count) group(s) found." 'ok'
        }
        Write-OperationLog -Context $script:AudCtx -Action 'AUDIT-EMPTY-GROUPS' -Target 'Domain' -Result 'OK' -Detail "$($rows.Count) found"
    } catch {
        if (Get-Command Set-Status -ErrorAction SilentlyContinue) { Set-Status "Empty groups audit failed: $($_.Exception.Message)" 'err' }
        Write-OperationLog -Context $script:AudCtx -Action 'AUDIT-EMPTY-GROUPS' -Target 'Domain' -Result 'FAIL' -Detail $_.Exception.Message
    }

    $cols = @('Name','GroupCategory','GroupScope','OU')
    Set-GridData -Grid $script:AudGrids['emptygrp'] -Data $rows -Columns $cols
}
#endregion

Export-ModuleMember -Function Invoke-EmptyGroupsAudit
