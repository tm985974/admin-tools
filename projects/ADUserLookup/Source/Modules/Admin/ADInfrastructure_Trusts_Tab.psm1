#region -- ADInfrastructure.Trusts.Tab.psm1 -----------------------------------
# Concern : Build-TrustTab - constructs the Trusts sub-tab with a trust
#           inventory grid plus an Export CSV button docked above the grid.
#           Trusts load automatically the first time this sub-tab is entered
#           (lazy load, same pattern as the Computers tab); no manual reload
#           control is exposed (export only, per spec).
# Load order: 104 - depends on ADInfrastructure.Trusts.Query (Get-TrustInventory),
#                             ADInfrastructure.RichText.Header (script scope),
#                             Services.AD.Reporting (New-SectionPanel, New-StdGrid,
#                                                    New-StdButton, Set-GridData,
#                                                    Export-ToCSV, Show-ExportResult,
#                                                    Write-OperationLog)
# Split from: ADInfrastructure.Tab.psm1
# Changes   : Removed the 'Trust Controls' section panel and the 'Load
#             Trusts' button. Trusts now auto-load on the sub-tab's first
#             Add_Enter (guarded by $script:TrustsLoaded). Export CSV remains
#             as a small button directly above the grid (no separate
#             controls panel, and no Refresh button - export only per spec).
#             Extracted the load logic into Invoke-TrustsLoad so the
#             auto-load path has a named function to call.
#endregion

#region -- Invoke-TrustsLoad ---------------------------------------------------
function Invoke-TrustsLoad {
    <#
    .SYNOPSIS
        Loads the domain trust inventory and populates $script:TrustGrid.
        Called once automatically on the sub-tab's first Add_Enter.
    #>
    if (-not $script:TrustGrid) { return }
    Set-Status 'Loading domain trusts...'
    $data = Get-TrustInventory
    $cols = @('SourceDomain','TargetDomain','TrustType','TrustDirection','TrustAttributes','Created','Modified')
    Set-GridData -Grid $script:TrustGrid -Data $data -Columns $cols
    Set-Status "Trusts loaded: $($data.Count) trust(s)" 'ok'
    Write-OperationLog -Context $script:InfraCtx -Action 'TRUST-INVENTORY' -Target 'Domain' `
        -Result 'OK' -Detail "$($data.Count) trusts"
}
#endregion

#region -- Build-TrustTab -----------------------------------------------------
function Build-TrustTab {
    param([System.Windows.Forms.TabPage]$Tab)
    $PAD = 8
    $TW  = $script:_TW
    $TH  = $script:_TH

    $BTN_BAR_H = 34
    $btnExport = New-StdButton -Text 'Export CSV' -X $PAD -Y $PAD -W 100 -H 26 -Parent $Tab

    $GRID_Y  = $PAD + $BTN_BAR_H
    $GRID_H  = $TH - $GRID_Y - $PAD
    $gridSec = New-SectionPanel -Parent $Tab -Title 'Domain Trusts' `
        -X $PAD -Y $GRID_Y -W ($TW-($PAD*2)) -H $GRID_H
    $script:TrustGrid = New-StdGrid -X 4 -Y 4 -W ($TW-($PAD*2)-10) -H ($GRID_H-30) -Parent $gridSec

    $btnExport.Add_Click({
        if ($script:TrustGrid.Rows.Count -eq 0) { return }
        $data = [System.Collections.Generic.List[PSCustomObject]]::new()
        foreach ($row in $script:TrustGrid.Rows) {
            $data.Add([PSCustomObject]@{
                SourceDomain    = $row.Cells['SourceDomain'].Value
                TargetDomain    = $row.Cells['TargetDomain'].Value
                TrustType       = $row.Cells['TrustType'].Value
                TrustDirection  = $row.Cells['TrustDirection'].Value
                TrustAttributes = $row.Cells['TrustAttributes'].Value
                Created         = $row.Cells['Created'].Value
                Modified        = $row.Cells['Modified'].Value
            })
        }
        $path = Export-ToCSV -Context $script:InfraCtx -Data $data -BaseName 'DomainTrusts'
        Show-ExportResult -FilePath $path
    })

    # Lazy auto-load: run once on first Enter, same pattern as the Computers tab.
    $script:TrustsLoaded = $false
    $Tab.Add_Enter({
        if (-not $script:TrustsLoaded) {
            $script:TrustsLoaded = $true
            Invoke-TrustsLoad
        }
    })
}
#endregion

Export-ModuleMember -Function Build-TrustTab, Invoke-TrustsLoad
