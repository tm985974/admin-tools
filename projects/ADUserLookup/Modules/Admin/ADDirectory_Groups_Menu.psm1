#region -- ADDirectory.Groups.Menu.psm1 ---------------------------------------
# Concern : Register-GroupGridMenu     - wires the context menu for the
#                                         standalone Groups tab's grid (all
#                                         domain groups). No "Remove User from
#                                         Group(s)" - there is no "selected
#                                         user" concept on that tab.
#           Register-UserGroupGridMenu - wires the context menu for the Users
#                                         tab's per-user Groups pane. Keeps
#                                         -ShowRemoveFromGroup, since that
#                                         grid shows the currently selected
#                                         user's membership and removing them
#                                         from a group is meaningful there.
#           Both own their respective grid's provider scriptblock, right-
#           click row-select MouseDown handler, and CellClick context update.
# Load order: 17 - depends on ADDirectory.Groups.Load (script scope),
#                            ADDirectory.Menus (New-GroupContextMenu)
# Split from: ADDirectory.Tab.psm1
# Changes   : Split the single Register-GroupGridMenu (which always passed
#             -ShowRemoveFromGroup and targeted the one shared $script:GrpGrid)
#             into two functions, one per grid, now that the standalone
#             Groups tab and the Users tab's per-user pane are separate grids
#             with separate caches (ADDirectory.Groups.Load).
#             Register-GroupGridMenu: targets $script:GrpGrid, no
#             -ShowRemoveFromGroup (all-domain-groups context has no single
#             selected user to remove).
#             Register-UserGroupGridMenu: targets $script:UserGrpGrid, keeps
#             -ShowRemoveFromGroup exactly as before.
#endregion

#region -- Register-GroupGridMenu ---------------------------------------------
function Register-GroupGridMenu {
    <#
    .SYNOPSIS
        Attaches the context menu and cell-click handler to the standalone
        Groups tab's grid (all domain groups in OU scope). Called once from
        Register-GroupsTab after grid creation.
    #>
    param([PSCustomObject]$Context)

    if (-not $script:GrpGrid) { return }

    $grpGridProvider = {
        $out = @()
        if ($script:GrpGrid) {
            foreach ($row in $script:GrpGrid.SelectedRows) {
                $v = $row.Cells['Name'].Value
                if ($v) { $out += [PSCustomObject]@{ Name=[string]$v; DN=[string]$row.Cells['DistinguishedName'].Value } }
            }
        }
        $out
    }

    $script:GrpGrid.ContextMenuStrip = New-GroupContextMenu -TargetProvider $grpGridProvider -Context $Context

    $script:GrpGrid.Add_MouseDown({
        param($s,$e)
        if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Right) { return }
        $hit = $script:GrpGrid.HitTest($e.X, $e.Y)
        if ($hit.RowIndex -ge 0 -and -not $script:GrpGrid.Rows[$hit.RowIndex].Selected) {
            $script:GrpGrid.ClearSelection()
            $script:GrpGrid.Rows[$hit.RowIndex].Selected = $true
        }
    })

    $script:GrpGrid.Add_CellClick({
        param($s,$e)
        if ($e.RowIndex -lt 0) { return }
        $row  = $script:GrpGrid.Rows[$e.RowIndex]
        $name = $row.Cells['Name'].Value
        $dn   = $row.Cells['DistinguishedName'].Value
        if (-not $name) { return }
        if (Get-Command Set-SelectedGroup -ErrorAction SilentlyContinue) {
            Set-SelectedGroup -Group ([PSCustomObject]@{ Name=$name; DistinguishedName=$dn })
        }
    })
}
#endregion

#region -- Register-UserGroupGridMenu -----------------------------------------
function Register-UserGroupGridMenu {
    <#
    .SYNOPSIS
        Attaches the context menu and cell-click handler to the Users tab's
        per-user Groups pane grid. Called once from Register-DirectoryTab
        after grid creation. Passes -ShowRemoveFromGroup since this grid
        shows the currently selected user's membership.
    #>
    param([PSCustomObject]$Context)

    if (-not $script:UserGrpGrid) { return }

    $userGrpGridProvider = {
        $out = @()
        if ($script:UserGrpGrid) {
            foreach ($row in $script:UserGrpGrid.SelectedRows) {
                $v = $row.Cells['Name'].Value
                if ($v) { $out += [PSCustomObject]@{ Name=[string]$v; DN=[string]$row.Cells['DistinguishedName'].Value } }
            }
        }
        $out
    }

    $script:UserGrpGrid.ContextMenuStrip = New-GroupContextMenu -TargetProvider $userGrpGridProvider -ShowRemoveFromGroup -Context $Context

    $script:UserGrpGrid.Add_MouseDown({
        param($s,$e)
        if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Right) { return }
        $hit = $script:UserGrpGrid.HitTest($e.X, $e.Y)
        if ($hit.RowIndex -ge 0 -and -not $script:UserGrpGrid.Rows[$hit.RowIndex].Selected) {
            $script:UserGrpGrid.ClearSelection()
            $script:UserGrpGrid.Rows[$hit.RowIndex].Selected = $true
        }
    })

    $script:UserGrpGrid.Add_CellClick({
        param($s,$e)
        if ($e.RowIndex -lt 0) { return }
        $row  = $script:UserGrpGrid.Rows[$e.RowIndex]
        $name = $row.Cells['Name'].Value
        $dn   = $row.Cells['DistinguishedName'].Value
        if (-not $name) { return }
        if (Get-Command Set-SelectedGroup -ErrorAction SilentlyContinue) {
            Set-SelectedGroup -Group ([PSCustomObject]@{ Name=$name; DistinguishedName=$dn })
        }
    })
}
#endregion

Export-ModuleMember -Function Register-GroupGridMenu, Register-UserGroupGridMenu
