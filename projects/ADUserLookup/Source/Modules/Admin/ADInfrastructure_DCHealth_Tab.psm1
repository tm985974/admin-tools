#region -- ADInfrastructure.DCHealth.Tab.psm1 ---------------------------------
# Concern : Build-DCHealthTab - constructs the DC Health sub-tab with a
#           results grid (colour-coded health status) plus Refresh and
#           Export HTML buttons docked above the grid. Health check runs
#           automatically the first time this sub-tab is entered (lazy
#           load, same pattern as the Computers tab); Refresh re-runs it
#           on demand thereafter.
# Load order: 102 - depends on ADInfrastructure.DCHealth.Query (Get-DCHealth),
#                             ADInfrastructure.RichText.Header (script scope),
#                             Services.AD.Reporting (New-SectionPanel, New-StdGrid,
#                                                    New-StdButton, Set-GridData,
#                                                    Export-ToHTML, Show-ExportResult,
#                                                    Write-OperationLog)
# Split from: ADInfrastructure.Tab.psm1
# Changes   : Removed the 'DC Health Controls' section panel and the
#             'Run Health Check' button. The health check now auto-runs on
#             the sub-tab's first Add_Enter (guarded by $script:DCHealthLoaded
#             so re-entering the tab doesn't re-query every time). Refresh
#             and Export HTML remain as small buttons directly above the
#             grid (no separate controls panel). Refresh re-runs the same
#             check logic on demand. Extracted the check logic into
#             Invoke-DCHealthRefresh so both the auto-load and the Refresh
#             button share one implementation.
#endregion

#region -- Invoke-DCHealthRefresh ---------------------------------------------
function Invoke-DCHealthRefresh {
    <#
    .SYNOPSIS
        Runs the DC health check and populates $script:DCGrid. Shared by the
        sub-tab's lazy auto-load (first Add_Enter) and the Refresh button.
    #>
    if (-not $script:DCGrid) { return }
    Set-Status 'Running DC health check...'
    $data = Get-DCHealth
    $cols = @('DCName','Site','IsGC','IsPDC','Ping','SYSVOL','NETLOGON','TimeDrift','ReplicationOK','OS')
    Set-GridData -Grid $script:DCGrid -Data $data -Columns $cols
    foreach ($row in $script:DCGrid.Rows) {
        $ping = $row.Cells['Ping'].Value
        $repl = $row.Cells['ReplicationOK'].Value
        if ($ping -eq 'FAIL')      { $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(255,199,206) }
        elseif ($repl -eq 'WARN')  { $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(255,235,156) }
        else                       { $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(198,239,206) }
    }
    Set-Status "DC health check complete. $($data.Count) DC(s)." 'ok'
    Write-OperationLog -Context $script:InfraCtx -Action 'DC-HEALTH' -Target 'Domain' `
        -Result 'OK' -Detail "$($data.Count) DCs checked"
}
#endregion

#region -- Build-DCHealthTab --------------------------------------------------
function Build-DCHealthTab {
    param([System.Windows.Forms.TabPage]$Tab)
    $PAD    = 8
    $F_UI_B = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $TW     = $script:_TW
    $TH     = $script:_TH

    $BTN_BAR_H = 34
    $btnRefresh      = New-StdButton -Text 'Refresh'      -X $PAD       -Y $PAD -W 90  -H 26 -Parent $Tab
    $btnRefresh.Font = $F_UI_B
    $btnExportH      = New-StdButton -Text 'Export HTML'  -X ($PAD+98) -Y $PAD -W 100 -H 26 -Parent $Tab

    $GRID_Y  = $PAD + $BTN_BAR_H
    $GRID_H  = $TH - $GRID_Y - $PAD
    $gridSec = New-SectionPanel -Parent $Tab -Title 'Domain Controller Health' `
        -X $PAD -Y $GRID_Y -W ($TW-($PAD*2)) -H $GRID_H
    $script:DCGrid = New-StdGrid -X 4 -Y 4 -W ($TW-($PAD*2)-10) -H ($GRID_H-30) -Parent $gridSec

    $btnRefresh.Add_Click({ Invoke-DCHealthRefresh })
    $btnExportH.Add_Click({
        if ($script:DCGrid.Rows.Count -eq 0) { return }
        $data = [System.Collections.Generic.List[PSCustomObject]]::new()
        foreach ($row in $script:DCGrid.Rows) {
            $data.Add([PSCustomObject]@{
                DCName=$row.Cells['DCName'].Value; Site=$row.Cells['Site'].Value
                IsGC=$row.Cells['IsGC'].Value; IsPDC=$row.Cells['IsPDC'].Value
                Ping=$row.Cells['Ping'].Value; SYSVOL=$row.Cells['SYSVOL'].Value
                NETLOGON=$row.Cells['NETLOGON'].Value; TimeDrift=$row.Cells['TimeDrift'].Value
                ReplicationOK=$row.Cells['ReplicationOK'].Value; OS=$row.Cells['OS'].Value
            })
        }
        $path = Export-ToHTML -Context $script:InfraCtx -Title 'DC Health Report' `
            -Subtitle "Domain: $($script:InfraCtx.Domain)" -Data $data -BaseName 'DCHealth'
        Show-ExportResult -FilePath $path
    })

    # Lazy auto-load: run once on first Enter, same pattern as the Computers tab.
    $script:DCHealthLoaded = $false
    $Tab.Add_Enter({
        if (-not $script:DCHealthLoaded) {
            $script:DCHealthLoaded = $true
            Invoke-DCHealthRefresh
        }
    })
}
#endregion

Export-ModuleMember -Function Build-DCHealthTab, Invoke-DCHealthRefresh
