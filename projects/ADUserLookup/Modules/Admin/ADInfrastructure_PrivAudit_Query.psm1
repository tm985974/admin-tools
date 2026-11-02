#region -- ADInfrastructure.PrivAudit.Query.psm1 ------------------------------
# Concern : Invoke-PrivAudit - audits privileged AD group membership and
#           adminCount=1 accounts. Populates PrivGrid with results and
#           applies row styling.
#           Get-PrivAuditGridData - extracts current PrivGrid rows for HTML
#           export. Folded in from the former ADGroups.PrivAudit.Results.psm1
#           (kept as a single file rather than a third small module, since
#           the two functions are tightly coupled to the same PrivGrid state).
# Load order: depends on Services.AD.Connection.Query (Get-OUFromDN),
#                        Services.AD.Reporting (Set-GridData, Write-OperationLog)
# Relocated from: ADGroups.PrivAudit.Query.psm1 + ADGroups.PrivAudit.Results.psm1
#                 (Groups tab removed; this function now lives under
#                 Infrastructure > Privileged Accounts). Context/grid scope
#                 updated from ADGroups ($script:GrpContext) to
#                 ADInfrastructure ($script:InfraCtx). Logging fallback
#                 switched from Write-GrpLog to Set-Status, consistent with
#                 other ADInfrastructure sub-tabs.
#endregion

#region -- Invoke-PrivAudit ---------------------------------------------------
function Invoke-PrivAudit {
    $privGroups = @(
        'Domain Admins','Schema Admins','Enterprise Admins',
        'Administrators','Account Operators','Backup Operators',
        'Print Operators','Server Operators','Group Policy Creator Owners'
    )
    $results = [System.Collections.Generic.List[PSCustomObject]]::new()
    $srv     = $script:InfraCtx.TargetDC

    foreach ($grp in $privGroups) {
        try {
            $members = Get-ADGroupMember -Identity $grp -Recursive -Server $srv -ErrorAction Stop |
                       Where-Object { $_.objectClass -eq 'user' }
            foreach ($m in $members) {
                try {
                    $u = Get-ADUser -Identity $m.SamAccountName `
                             -Properties Enabled,LastLogonDate,adminCount,DistinguishedName `
                             -Server $srv -ErrorAction Stop
                    $results.Add([PSCustomObject]@{
                        PrivilegedGroup = $grp
                        DisplayName     = $m.Name
                        SamAccountName  = $m.SamAccountName
                        Enabled         = [string]$u.Enabled
                        LastLogon       = if ($u.LastLogonDate) { $u.LastLogonDate.ToString('yyyy-MM-dd') } else { 'Never' }
                        AdminCount      = [string]$u.adminCount
                        OU              = Get-OUFromDN -DN $u.DistinguishedName
                    })
                } catch { }
            }
        } catch { }
    }

    try {
        $adminCountUsers = Get-ADUser -Filter 'adminCount -eq 1' `
                               -Properties Enabled,LastLogonDate,adminCount,DistinguishedName `
                               -Server $srv -ErrorAction Stop
        foreach ($u in $adminCountUsers) {
            $already = $results | Where-Object { $_.SamAccountName -eq $u.SamAccountName }
            if (-not $already) {
                $results.Add([PSCustomObject]@{
                    PrivilegedGroup = '(adminCount=1 only)'
                    DisplayName     = $u.Name
                    SamAccountName  = $u.SamAccountName
                    Enabled         = [string]$u.Enabled
                    LastLogon       = if ($u.LastLogonDate) { $u.LastLogonDate.ToString('yyyy-MM-dd') } else { 'Never' }
                    AdminCount      = '1'
                    OU              = Get-OUFromDN -DN $u.DistinguishedName
                })
            }
        }
    } catch { }

    $cols = @('PrivilegedGroup','DisplayName','SamAccountName','Enabled','LastLogon','AdminCount','OU')
    Set-GridData -Grid $script:PrivGrid -Data $results -Columns $cols

    foreach ($row in $script:PrivGrid.Rows) {
        if ($row.Cells['Enabled'].Value -eq 'False') {
            $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(255,199,206)
        } elseif ($row.Cells['LastLogon'].Value -eq 'Never') {
            $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(255,235,156)
        }
    }

    if (Get-Command Set-Status -ErrorAction SilentlyContinue) {
        Set-Status "Privileged audit: $($results.Count) privileged account entries found." 'ok'
    }
    Write-OperationLog -Context $script:InfraCtx -Action 'PRIV-AUDIT' -Target 'PrivilegedGroups' `
        -Result 'OK' -Detail "$($results.Count) entries found"
}
#endregion

#region -- Get-PrivAuditGridData ----------------------------------------------
function Get-PrivAuditGridData {
    <#
    .SYNOPSIS
        Extracts the current PrivGrid rows as a list of PSCustomObjects.
        Used by the Export HTML button in Build-PrivAuditTab.
    #>
    $data = [System.Collections.Generic.List[PSCustomObject]]::new()
    if (-not $script:PrivGrid) { return $data }
    foreach ($row in $script:PrivGrid.Rows) {
        $data.Add([PSCustomObject]@{
            PrivilegedGroup = $row.Cells['PrivilegedGroup'].Value
            DisplayName     = $row.Cells['DisplayName'].Value
            SamAccountName  = $row.Cells['SamAccountName'].Value
            Enabled         = $row.Cells['Enabled'].Value
            LastLogon       = $row.Cells['LastLogon'].Value
            AdminCount      = $row.Cells['AdminCount'].Value
            OU              = $row.Cells['OU'].Value
        })
    }
    return $data
}
#endregion

Export-ModuleMember -Function Invoke-PrivAudit, Get-PrivAuditGridData
