#region -- ADInfrastructure.ForestInfo.Display.psm1 --------------------------
# Concern : Build-LevelTab - constructs the Forest/Domain Level sub-tab with
#           a RichTextBox for structured forest/domain/password-policy output
#           plus an Export HTML button docked above it. Info loads
#           automatically the first time this sub-tab is entered (lazy load,
#           same pattern as the Computers tab); no manual reload control is
#           exposed (export only, per spec).
# Load order: 112 - depends on ADInfrastructure.ForestInfo.Query (Read-ForestDomainInfo),
#                             ADInfrastructure.RichText.Header (script scope),
#                             Services.AD.Reporting (New-SectionPanel, New-StdButton,
#                                                    Export-ToHTML, Show-ExportResult)
# Split from: ADInfrastructure.Tab.psm1
# Changes   : Removed the 'Forest and Domain Information' section panel and
#             the 'Load Info' button. Info now auto-loads on the sub-tab's
#             first Add_Enter (guarded by $script:LevelInfoLoaded). Export
#             HTML remains as a small button directly above the RichTextBox
#             (no separate controls panel, and no Refresh button - export
#             only per spec).
#endregion

#region -- Build-LevelTab -----------------------------------------------------
function Build-LevelTab {
    param([System.Windows.Forms.TabPage]$Tab)
    $PAD    = 8
    $F_MONO = New-Object System.Drawing.Font('Consolas', 9)
    $TW     = $script:_TW
    $TH     = $script:_TH

    $BTN_BAR_H = 34
    $btnExport = New-StdButton -Text 'Export HTML' -X $PAD -Y $PAD -W 100 -H 26 -Parent $Tab

    $INFO_Y  = $PAD + $BTN_BAR_H
    $INFO_H  = $TH - $INFO_Y - $PAD
    $infoSec = New-SectionPanel -Parent $Tab -Title 'Forest / Domain Details' `
        -X $PAD -Y $INFO_Y -W ($TW-($PAD*2)) -H $INFO_H

    $script:LevelRtb              = New-Object System.Windows.Forms.RichTextBox
    $script:LevelRtb.Dock         = 'Fill'
    $script:LevelRtb.Font         = $F_MONO
    $script:LevelRtb.ReadOnly     = $true
    $script:LevelRtb.BackColor    = [System.Drawing.Color]::FromArgb(245,248,252)
    $script:LevelRtb.BorderStyle  = 'None'
    $infoSec.Controls.Add($script:LevelRtb)
    $script:LevelData = $null

    $btnExport.Add_Click({
        if (-not $script:LevelData) { return }
        $path = Export-ToHTML -Context $script:InfraCtx -Title 'Forest and Domain Report' `
            -Subtitle "Forest: $($script:InfraCtx.ForestRoot)" `
            -Data $script:LevelData -BaseName 'ForestDomainInfo'
        Show-ExportResult -FilePath $path
    })

    # Lazy auto-load: run once on first Enter, same pattern as the Computers tab.
    $script:LevelInfoLoaded = $false
    $Tab.Add_Enter({
        if (-not $script:LevelInfoLoaded) {
            $script:LevelInfoLoaded = $true
            if (Get-Command Read-ForestDomainInfo -ErrorAction SilentlyContinue) {
                Read-ForestDomainInfo
            }
        }
    })
}
#endregion

Export-ModuleMember -Function Build-LevelTab
