#region -- ADInfrastructure.PrivAudit.Tab.psm1 --------------------------------
# Concern : Build-PrivAuditTab - constructs the Privileged Accounts sub-tab
#           UI: Refresh/Export buttons docked above the grid, an info label,
#           and the results grid. Audit runs automatically the first time
#           this sub-tab is entered (lazy load, same pattern as the
#           Computers tab); Refresh re-runs it on demand thereafter.
# Load order: depends on ADInfrastructure.PrivAudit.Query (Invoke-PrivAudit,
#                        Get-PrivAuditGridData),
#                        Services.AD.Reporting (New-SectionPanel, New-StdGrid,
#                                               New-StdButton, Export-ToHTML,
#                                               Show-ExportResult)
# Relocated from: ADGroups.PrivAudit.Tab.psm1 (Groups tab removed; this is now
#                 the last sub-tab under Infrastructure > Privileged
#                 Accounts). Context scope updated from ADGroups
#                 ($script:GrpContext) to ADInfrastructure ($script:InfraCtx).
#                 $script:_TW / $script:_TH are set by
#                 Register-InfrastructureTab (same pattern as before, no
#                 change needed there beyond the new page entry).
# Changes   : Removed the 'Privileged Group Audit' section panel and the
#             'Run Audit' button (redundant with Refresh, which did the same
#             thing). Audit now auto-runs on the sub-tab's first Add_Enter
#             (guarded by $script:PrivAuditLoaded). Refresh and Export HTML
#             remain as small buttons directly above the grid; the info
#             label moved up to sit beside them since the controls panel
#             that used to host it is gone.
#endregion

#region -- Build-PrivAuditTab -------------------------------------------------
function Build-PrivAuditTab {
    param([System.Windows.Forms.TabPage]$Tab)
    $PAD  = 8
    $F_UI = New-Object System.Drawing.Font('Segoe UI', 9)
    $TW   = $script:_TW
    $TH   = $script:_TH

    $BTN_BAR_H  = 34
    $btnRefresh = New-StdButton -Text 'Refresh'     -X $PAD       -Y $PAD -W 90  -H 26 -Parent $Tab
    $btnExport  = New-StdButton -Text 'Export HTML' -X ($PAD+98) -Y $PAD -W 100 -H 26 -Parent $Tab

    $lInfo           = New-Object System.Windows.Forms.Label
    $lInfo.Text      = 'Audits: Domain Admins, Schema Admins, Enterprise Admins, Administrators, Account Operators, Backup Operators, Print Operators, Server Operators, Group Policy Creator Owners, adminCount=1 accounts'
    $lInfo.Location  = New-Object System.Drawing.Point(($PAD+206), ($PAD+2))
    $lInfo.Size      = New-Object System.Drawing.Size(($TW-($PAD*2)-216), 24)
    $lInfo.Font      = $F_UI
    $lInfo.ForeColor = [System.Drawing.Color]::DimGray
    $Tab.Controls.Add($lInfo)

    $GRID_Y  = $PAD + $BTN_BAR_H
    $GRID_H  = $TH - $GRID_Y - $PAD
    $gridSec = New-SectionPanel -Parent $Tab -Title 'Results' `
        -X $PAD -Y $GRID_Y -W ($TW-($PAD*2)) -H $GRID_H
    $script:PrivGrid = New-StdGrid -X 4 -Y 4 -W ($TW-($PAD*2)-10) -H ($GRID_H-30) -Parent $gridSec

    $btnRefresh.Add_Click({ Invoke-PrivAudit })
    $btnExport.Add_Click({
        if ($script:PrivGrid.Rows.Count -eq 0) { return }
        $data = Get-PrivAuditGridData
        $path = Export-ToHTML -Context $script:InfraCtx -Title 'Privileged Group Audit' `
            -Subtitle "Domain: $($script:InfraCtx.Domain)" -Data $data -BaseName 'PrivAudit'
        Show-ExportResult -FilePath $path
    })

    # Lazy auto-load: run once on first Enter, same pattern as the Computers tab.
    $script:PrivAuditLoaded = $false
    $Tab.Add_Enter({
        if (-not $script:PrivAuditLoaded) {
            $script:PrivAuditLoaded = $true
            if (Get-Command Invoke-PrivAudit -ErrorAction SilentlyContinue) {
                Invoke-PrivAudit
            }
        }
    })
}
#endregion

Export-ModuleMember -Function Build-PrivAuditTab
