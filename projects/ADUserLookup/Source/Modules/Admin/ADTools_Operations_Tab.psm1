#region -- ADTools.Operations.Tab.psm1 ----------------------------------------
# Concern : Build-OpLogTab - constructs the Operation Log sub-tab with day
#           range NUD, filter text box, Load/Refresh/Open Folder buttons,
#           and log entries grid. Wires all events.
# Load order: 122 - depends on ADTools.Operations.ReadLog (Read-OpLog),
#                            ADTools.Operations.SelectLog (Select-OpLog),
#                            ADTools.PasswordGenerator.Engine (script scope),
#                            Services.AD.Reporting (New-SectionPanel, New-StdGrid,
#                                                   New-StdButton, Set-Placeholder)
# Split from: ADTools.Tab.psm1
#endregion

#region -- Build-OpLogTab -----------------------------------------------------
function Build-OpLogTab {
    param([System.Windows.Forms.TabPage]$Tab)
    $PAD    = 8
    $F_UI   = New-Object System.Drawing.Font('Segoe UI', 9)
    $F_UI_B = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $TW     = $script:_TW; $TH = $script:_TH

    $pCtrl = New-SectionPanel -Parent $Tab -Title 'Log Controls' `
        -X $PAD -Y $PAD -W ($TW-($PAD*2)) -ContentH 36

    $lbDays           = New-Object System.Windows.Forms.Label
    $lbDays.Text      = 'Show last (days):'
    $lbDays.Location  = New-Object System.Drawing.Point(6, 8)
    $lbDays.Size      = New-Object System.Drawing.Size(120, 22); $lbDays.Font = $F_UI
    $pCtrl.Controls.Add($lbDays)

    $script:LogNud          = New-Object System.Windows.Forms.NumericUpDown
    $script:LogNud.Location = New-Object System.Drawing.Point(128, 6)
    $script:LogNud.Size     = New-Object System.Drawing.Size(70, 24); $script:LogNud.Font = $F_UI
    $script:LogNud.Minimum  = 1; $script:LogNud.Maximum = 365; $script:LogNud.Value = 7
    $pCtrl.Controls.Add($script:LogNud)

    $lbFilter          = New-Object System.Windows.Forms.Label
    $lbFilter.Text     = 'Filter:'
    $lbFilter.Location = New-Object System.Drawing.Point(210, 8)
    $lbFilter.Size     = New-Object System.Drawing.Size(44, 22); $lbFilter.Font = $F_UI
    $pCtrl.Controls.Add($lbFilter)

    $script:LogTbFilter          = New-Object System.Windows.Forms.TextBox
    $script:LogTbFilter.Location = New-Object System.Drawing.Point(256, 6)
    $script:LogTbFilter.Size     = New-Object System.Drawing.Size(240, 24)
    $script:LogTbFilter.Font     = $F_UI
    Set-Placeholder -TextBox $script:LogTbFilter -Text 'Action, target, admin...'
    $pCtrl.Controls.Add($script:LogTbFilter)

    $btnLoad      = New-StdButton -Text 'Load Log'        -X 504 -Y 6 -W 90  -H 26 -Parent $pCtrl
    $btnLoad.Font = $F_UI_B
    $btnRefresh   = New-StdButton -Text 'Refresh'         -X 602 -Y 6 -W 80  -H 26 -Parent $pCtrl
    $btnOpenDir   = New-StdButton -Text 'Open Log Folder' -X 690 -Y 6 -W 120 -H 26 -Parent $pCtrl

    $CTRL_SEC_H = 36 + 24 + 1
    $GRID_Y     = $PAD + $CTRL_SEC_H + $PAD; $GRID_H = $TH - $GRID_Y - ($PAD*2)
    $gridSec    = New-SectionPanel -Parent $Tab -Title 'Operation Log Entries' `
        -X $PAD -Y $GRID_Y -W ($TW-($PAD*2)) -H $GRID_H
    $script:LogGrid       = New-StdGrid -X 4 -Y 4 -W ($TW-($PAD*2)-10) -H ($GRID_H-30) -Parent $gridSec
    $script:LogAllEntries = $null

    $Tab.Add_Enter({ Read-OpLog })
    $btnLoad.Add_Click({ Read-OpLog })
    $btnRefresh.Add_Click({ Read-OpLog })
    $script:LogTbFilter.Add_TextChanged({ Select-OpLog })
    $btnOpenDir.Add_Click({
        $dir = $script:ToolsCtx.LogsDir
        if ($dir -and (Test-Path $dir)) { Start-Process explorer.exe $dir }
    })
}
#endregion

Export-ModuleMember -Function Build-OpLogTab
