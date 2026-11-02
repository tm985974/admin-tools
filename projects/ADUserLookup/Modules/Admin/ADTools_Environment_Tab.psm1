#region -- ADTools.Environment.Tab.psm1 ---------------------------------------
# Concern : Build-EnvTab - constructs the Environment Report sub-tab with
#           Scan Environment and Export HTML buttons, capability matrix grid,
#           and structured RTB report. Wires all events.
# Load order: 125 - depends on ADTools.Environment.Report (Update-EnvReport),
#                            ADTools.PasswordGenerator.Engine (script scope),
#                            Services.AD.Reporting (New-SectionPanel, New-StdGrid,
#                                                   New-StdButton, Export-ToHTML,
#                                                   Show-ExportResult),
#                            Services.AD.Connection (Get-ADCapabilities)
# Split from: ADTools.Tab.psm1
# Changes   : Removed dependency on ADTools.Environment.Grid
#             (Get-EnvGridData) - that module was orphaned (this tab's own
#             Export HTML button already used $script:EnvData directly) and
#             has been removed from the project.
#endregion

#region -- Build-EnvTab -------------------------------------------------------
function Build-EnvTab {
    param([System.Windows.Forms.TabPage]$Tab)
    $PAD    = 8
    $F_UI_B = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $F_MONO = New-Object System.Drawing.Font('Consolas', 9)
    $TW     = $script:_TW; $TH = $script:_TH

    $pCtrl = New-SectionPanel -Parent $Tab -Title 'Environment Controls' `
        -X $PAD -Y $PAD -W ($TW-($PAD*2)) -ContentH 36

    $btnScan      = New-StdButton -Text 'Scan Environment' -X 6   -Y 6 -W 140 -H 26 -Parent $pCtrl
    $btnScan.Font = $F_UI_B
    $btnExport    = New-StdButton -Text 'Export HTML'      -X 154 -Y 6 -W 100 -H 26 -Parent $pCtrl

    $CTRL_SEC_H = 36 + 24 + 1
    $GRID_Y     = $PAD + $CTRL_SEC_H + $PAD
    $GRID_H     = [int](($TH - $GRID_Y - ($PAD*3)) * 0.45)
    $gridSec    = New-SectionPanel -Parent $Tab -Title 'Capability Matrix' `
        -X $PAD -Y $GRID_Y -W ($TW-($PAD*2)) -H $GRID_H
    $script:EnvGrid = New-StdGrid -X 4 -Y 4 -W ($TW-($PAD*2)-10) -H ($GRID_H-30) -Parent $gridSec

    $RTB_Y  = $GRID_Y + $GRID_H + $PAD; $RTB_H = $TH - $RTB_Y - ($PAD*2)
    $rtbSec = New-SectionPanel -Parent $Tab -Title 'Detailed Report' `
        -X $PAD -Y $RTB_Y -W ($TW-($PAD*2)) -H $RTB_H

    $script:EnvRtb              = New-Object System.Windows.Forms.RichTextBox
    $script:EnvRtb.Dock         = 'Fill'; $script:EnvRtb.Font = $F_MONO
    $script:EnvRtb.ReadOnly     = $true
    $script:EnvRtb.BackColor    = [System.Drawing.Color]::FromArgb(245,248,252)
    $script:EnvRtb.BorderStyle  = 'None'
    $rtbSec.Controls.Add($script:EnvRtb)
    $script:EnvData = $null

    $Tab.Add_Enter({
        if ($script:ToolsCtx.Capabilities -and -not $script:EnvData) {
            Update-EnvReport -Caps $script:ToolsCtx.Capabilities
        }
    })
    $btnScan.Add_Click({
        Set-Status 'Scanning environment...'
        if (Get-Command Get-ADCapabilities -ErrorAction SilentlyContinue) {
            $caps = Get-ADCapabilities
            $script:ToolsCtx.Capabilities = $caps
            Update-EnvReport -Caps $caps
            Set-Status 'Environment scan complete.' 'ok'
        }
    })
    $btnExport.Add_Click({
        if (-not $script:EnvData) { return }
        $path = Export-ToHTML -Context $script:ToolsCtx -Title 'AD-Admin Environment Report' `
            -Subtitle "Machine: $env:COMPUTERNAME" -Data $script:EnvData -BaseName 'EnvironmentReport'
        Show-ExportResult -FilePath $path
    })
}
#endregion

Export-ModuleMember -Function Build-EnvTab
