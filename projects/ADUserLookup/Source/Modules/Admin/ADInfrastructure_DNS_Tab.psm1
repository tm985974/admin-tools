#region -- ADInfrastructure.DNS.Tab.psm1 --------------------------------------
# Concern : Build-DNSTab - constructs the DNS Lookup sub-tab with name/type/
#           server controls and results grid. Wires Lookup button and Enter key.
# Load order: 106 - depends on ADInfrastructure.DNS.Lookup (Invoke-DNSLookup),
#                             ADInfrastructure.RichText.Header (script scope),
#                             Services.AD.Reporting (New-SectionPanel, New-StdGrid,
#                                                    New-StdButton, Set-Placeholder)
# Split from: ADInfrastructure.Tab.psm1
#endregion

#region -- Build-DNSTab -------------------------------------------------------
function Build-DNSTab {
    param([System.Windows.Forms.TabPage]$Tab)
    $PAD    = 8
    $F_UI   = New-Object System.Drawing.Font('Segoe UI', 9)
    $F_UI_B = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $TW     = $script:_TW
    $TH     = $script:_TH

    $pCtrl = New-SectionPanel -Parent $Tab -Title 'DNS Record Lookup' `
        -X $PAD -Y $PAD -W ($TW-($PAD*2)) -ContentH 36

    $lbQ          = New-Object System.Windows.Forms.Label
    $lbQ.Text     = 'Name or IP:'; $lbQ.Location = New-Object System.Drawing.Point(6, 8)
    $lbQ.Size     = New-Object System.Drawing.Size(80, 22); $lbQ.Font = $F_UI
    $pCtrl.Controls.Add($lbQ)

    $script:DNSTbQuery          = New-Object System.Windows.Forms.TextBox
    $script:DNSTbQuery.Location = New-Object System.Drawing.Point(88, 6)
    $script:DNSTbQuery.Size     = New-Object System.Drawing.Size(280, 24)
    $script:DNSTbQuery.Font     = $F_UI
    Set-Placeholder -TextBox $script:DNSTbQuery -Text 'hostname, FQDN, or IP address'
    $pCtrl.Controls.Add($script:DNSTbQuery)

    $lbType          = New-Object System.Windows.Forms.Label
    $lbType.Text     = 'Type:'; $lbType.Location = New-Object System.Drawing.Point(376, 8)
    $lbType.Size     = New-Object System.Drawing.Size(36, 22); $lbType.Font = $F_UI
    $pCtrl.Controls.Add($lbType)

    $script:DNSCmbType                = New-Object System.Windows.Forms.ComboBox
    $script:DNSCmbType.Location       = New-Object System.Drawing.Point(414, 6)
    $script:DNSCmbType.Size           = New-Object System.Drawing.Size(120, 24)
    $script:DNSCmbType.DropDownStyle  = 'DropDownList'
    $script:DNSCmbType.Font           = $F_UI
    @('A','AAAA','CNAME','MX','NS','PTR','SOA','SRV','TXT','All') |
        ForEach-Object { [void]$script:DNSCmbType.Items.Add($_) }
    $script:DNSCmbType.SelectedIndex  = 0
    $pCtrl.Controls.Add($script:DNSCmbType)

    $lbSrv        = New-Object System.Windows.Forms.Label
    $lbSrv.Text   = 'DNS Server:'; $lbSrv.Location = New-Object System.Drawing.Point(546, 8)
    $lbSrv.Size   = New-Object System.Drawing.Size(78, 22); $lbSrv.Font = $F_UI
    $pCtrl.Controls.Add($lbSrv)

    $script:DNSTbSrv          = New-Object System.Windows.Forms.TextBox
    $script:DNSTbSrv.Location = New-Object System.Drawing.Point(626, 6)
    $script:DNSTbSrv.Size     = New-Object System.Drawing.Size(180, 24)
    $script:DNSTbSrv.Font     = $F_UI
    Set-Placeholder -TextBox $script:DNSTbSrv -Text 'blank = use DC'
    $pCtrl.Controls.Add($script:DNSTbSrv)

    $btnLookup      = New-StdButton -Text 'Lookup' -X 814 -Y 6 -W 80 -H 26 -Parent $pCtrl
    $btnLookup.Font = $F_UI_B

    $CTRL_SEC_H = 36 + 24 + 1
    $RESULT_Y   = $PAD + $CTRL_SEC_H + $PAD
    $resSec     = New-SectionPanel -Parent $Tab -Title 'DNS Results' `
        -X $PAD -Y $RESULT_Y -W ($TW-($PAD*2)) -H ($TH - $RESULT_Y - ($PAD*2))
    $script:DNSGrid = New-StdGrid -X 4 -Y 4 -W ($TW-($PAD*2)-10) `
        -H (($TH - $RESULT_Y - ($PAD*2))-30) -Parent $resSec

    $script:DNSTbQuery.Add_KeyDown({
        param($s,$e); if ($e.KeyCode -eq 'Return') { $btnLookup.PerformClick() }
    })
    $btnLookup.Add_Click({
        $query = $script:DNSTbQuery.Text.Trim(); if (-not $query) { return }
        Invoke-DNSLookup -Query $query -Type $script:DNSCmbType.SelectedItem `
            -Server $script:DNSTbSrv.Text.Trim()
    })
    $Tab.Add_Enter({
        if (-not $script:DNSTbSrv.Text -and $script:InfraCtx.TargetDC) {
            $script:DNSTbSrv.Text = $script:InfraCtx.TargetDC
        }
    })
}
#endregion

Export-ModuleMember -Function Build-DNSTab
