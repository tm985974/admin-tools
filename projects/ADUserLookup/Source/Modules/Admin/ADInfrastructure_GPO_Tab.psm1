#region -- ADInfrastructure.GPO.Tab.psm1 --------------------------------------
# Concern : Build-GPOScopeTab - constructs the GPO Scope sub-tab with OU picker,
#           Get and Export HTML buttons, GPO links grid with enforced/disabled styling.
# Load order: 110 - depends on ADInfrastructure.GPO.Scope (Invoke-GPOScope),
#                             ADInfrastructure.RichText.Header (script scope),
#                             Services.AD.Reporting (New-SectionPanel, New-StdGrid,
#                                                    New-StdButton, Export-ToHTML,
#                                                    Show-ExportResult)
# Split from: ADInfrastructure.Tab.psm1
#endregion

#region -- Build-GPOScopeTab --------------------------------------------------
function Build-GPOScopeTab {
    param([System.Windows.Forms.TabPage]$Tab)
    $PAD    = 8
    $F_UI   = New-Object System.Drawing.Font('Segoe UI', 9)
    $F_UI_B = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $TW     = $script:_TW
    $TH     = $script:_TH

    $pCtrl = New-SectionPanel -Parent $Tab -Title 'GPO Scope Viewer' `
        -X $PAD -Y $PAD -W ($TW-($PAD*2)) -ContentH 36

    $lbOU        = New-Object System.Windows.Forms.Label
    $lbOU.Text   = 'OU or object DN:'; $lbOU.Location = New-Object System.Drawing.Point(6, 8)
    $lbOU.Size   = New-Object System.Drawing.Size(110, 22); $lbOU.Font = $F_UI
    $pCtrl.Controls.Add($lbOU)

    $script:GPOTbOU           = New-Object System.Windows.Forms.TextBox
    $script:GPOTbOU.Location  = New-Object System.Drawing.Point(118, 6)
    $script:GPOTbOU.Size      = New-Object System.Drawing.Size(440, 24)
    $script:GPOTbOU.Font      = $F_UI
    $script:GPOTbOU.ReadOnly  = $true
    $script:GPOTbOU.BackColor = [System.Drawing.Color]::FromArgb(245,245,245)
    $pCtrl.Controls.Add($script:GPOTbOU)

    $btnBrowseGPO     = New-StdButton -Text 'Browse...'     -X 566 -Y 6 -W 80  -H 26 -Parent $pCtrl
    $btnGetGPO        = New-StdButton -Text 'Get GPO Scope' -X 654 -Y 6 -W 120 -H 26 -Parent $pCtrl
    $btnGetGPO.Font   = $F_UI_B
    $btnExportGPO     = New-StdButton -Text 'Export HTML'   -X 782 -Y 6 -W 100 -H 26 -Parent $pCtrl

    $CTRL_SEC_H = 36 + 24 + 1
    $GRID_Y     = $PAD + $CTRL_SEC_H + $PAD
    $GRID_H     = $TH - $GRID_Y - ($PAD*2)
    $gridSec    = New-SectionPanel -Parent $Tab `
        -Title 'GPO Links  (enforced = blue, disabled links = gray text)' `
        -X $PAD -Y $GRID_Y -W ($TW-($PAD*2)) -H $GRID_H
    $script:GPOGrid  = New-StdGrid -X 4 -Y 4 -W ($TW-($PAD*2)-10) -H ($GRID_H-30) -Parent $gridSec
    $script:GPOData  = $null

    $btnBrowseGPO.Add_Click({
        if (Get-Command Show-OUPicker -ErrorAction SilentlyContinue) {
            $dn = Show-OUPicker -Context $script:InfraCtx
            if ($dn) { $script:GPOTbOU.Text = $dn }
        }
    })
    $btnGetGPO.Add_Click({
        $OUDN = $script:GPOTbOU.Text.Trim()
        if (-not $OUDN) { Set-Status 'Select an OU first.' 'warn'; return }
        Invoke-GPOScope -OUDN $OUDN
    })
    $btnExportGPO.Add_Click({
        if (-not $script:GPOData -or $script:GPOData.Count -eq 0) { return }
        $path = Export-ToHTML -Context $script:InfraCtx -Title 'GPO Scope Report' `
            -Subtitle "OU chain from: $($script:GPOTbOU.Text)" -Data $script:GPOData -BaseName 'GPOScope'
        Show-ExportResult -FilePath $path
    })
}
#endregion

Export-ModuleMember -Function Build-GPOScopeTab
