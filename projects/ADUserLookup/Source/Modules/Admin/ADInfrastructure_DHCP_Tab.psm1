#region -- ADInfrastructure.DHCP.Tab.psm1 -------------------------------------
# Concern : Build-DHCPTab - constructs the DHCP Leases sub-tab with server/filter
#           inputs, results grid. Wires Get Leases, Export CSV, and live filter.
# Load order: 108 - depends on ADInfrastructure.DHCP.Query (Invoke-DHCPLeases),
#                             ADInfrastructure.RichText.Header (script scope),
#                             Services.AD.Reporting (New-SectionPanel, New-StdGrid,
#                                                    New-StdButton, Set-Placeholder,
#                                                    Set-GridData, Export-ToCSV,
#                                                    Show-ExportResult)
# Split from: ADInfrastructure.Tab.psm1
#endregion

#region -- Build-DHCPTab ------------------------------------------------------
function Build-DHCPTab {
    param([System.Windows.Forms.TabPage]$Tab)
    $PAD    = 8
    $F_UI   = New-Object System.Drawing.Font('Segoe UI', 9)
    $F_UI_B = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $TW     = $script:_TW
    $TH     = $script:_TH

    $pCtrl = New-SectionPanel -Parent $Tab -Title 'DHCP Lease Lookup' `
        -X $PAD -Y $PAD -W ($TW-($PAD*2)) -ContentH 36

    $lbSrv        = New-Object System.Windows.Forms.Label
    $lbSrv.Text   = 'DHCP Server:'; $lbSrv.Location = New-Object System.Drawing.Point(6, 8)
    $lbSrv.Size   = New-Object System.Drawing.Size(84, 22); $lbSrv.Font = $F_UI
    $pCtrl.Controls.Add($lbSrv)

    $script:DHCPTbSrv          = New-Object System.Windows.Forms.TextBox
    $script:DHCPTbSrv.Location = New-Object System.Drawing.Point(92, 6)
    $script:DHCPTbSrv.Size     = New-Object System.Drawing.Size(220, 24)
    $script:DHCPTbSrv.Font     = $F_UI
    Set-Placeholder -TextBox $script:DHCPTbSrv -Text 'DHCP server hostname or IP'
    $pCtrl.Controls.Add($script:DHCPTbSrv)

    $lbFilter        = New-Object System.Windows.Forms.Label
    $lbFilter.Text   = 'Filter (IP, MAC, or hostname):'
    $lbFilter.Location = New-Object System.Drawing.Point(324, 8)
    $lbFilter.Size   = New-Object System.Drawing.Size(196, 22); $lbFilter.Font = $F_UI
    $pCtrl.Controls.Add($lbFilter)

    $script:DHCPTbFlt          = New-Object System.Windows.Forms.TextBox
    $script:DHCPTbFlt.Location = New-Object System.Drawing.Point(522, 6)
    $script:DHCPTbFlt.Size     = New-Object System.Drawing.Size(220, 24)
    $script:DHCPTbFlt.Font     = $F_UI
    $pCtrl.Controls.Add($script:DHCPTbFlt)

    $btnGet      = New-StdButton -Text 'Get Leases' -X 750 -Y 6 -W 100 -H 26 -Parent $pCtrl
    $btnGet.Font = $F_UI_B
    $btnExport   = New-StdButton -Text 'Export CSV' -X 858 -Y 6 -W 90  -H 26 -Parent $pCtrl

    $lbNote           = New-Object System.Windows.Forms.Label
    $lbNote.Text      = 'Requires RSAT DHCP Tools (DhcpServer module) and access to the DHCP server.'
    $lbNote.Location  = New-Object System.Drawing.Point(956, 10)
    $lbNote.Size      = New-Object System.Drawing.Size(500, 18)
    $lbNote.Font      = New-Object System.Drawing.Font('Segoe UI', 7.5)
    $lbNote.ForeColor = [System.Drawing.Color]::DimGray
    $pCtrl.Controls.Add($lbNote)

    $CTRL_SEC_H = 36 + 24 + 1
    $GRID_Y     = $PAD + $CTRL_SEC_H + $PAD
    $GRID_H     = $TH - $GRID_Y - ($PAD*2)
    $gridSec    = New-SectionPanel -Parent $Tab -Title 'DHCP Leases' `
        -X $PAD -Y $GRID_Y -W ($TW-($PAD*2)) -H $GRID_H
    $script:DHCPGrid  = New-StdGrid -X 4 -Y 4 -W ($TW-($PAD*2)-10) -H ($GRID_H-30) -Parent $gridSec
    $script:DHCPData  = $null

    $btnGet.Add_Click({ Invoke-DHCPLeases })
    $btnExport.Add_Click({
        if (-not $script:DHCPData -or $script:DHCPData.Count -eq 0) { return }
        $path = Export-ToCSV -Context $script:InfraCtx -Data $script:DHCPData -BaseName 'DHCPLeases'
        Show-ExportResult -FilePath $path
    })
    $script:DHCPTbFlt.Add_TextChanged({
        if ($null -eq $script:DHCPData) { return }
        $q = $script:DHCPTbFlt.Text.Trim().ToLower()
        $filtered = if ($q) {
            @($script:DHCPData | Where-Object {
                $_.IPAddress -like "*$q*" -or $_.ClientId -like "*$q*" -or $_.HostName -like "*$q*"
            })
        } else { @($script:DHCPData) }
        Set-GridData -Grid $script:DHCPGrid -Data $filtered `
            -Columns @('IPAddress','ClientId','HostName','LeaseExpiry','Scope','AddressState')
    })
}
#endregion

Export-ModuleMember -Function Build-DHCPTab
