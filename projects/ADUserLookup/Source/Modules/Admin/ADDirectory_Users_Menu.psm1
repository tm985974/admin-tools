#region -- ADDirectory.Users.Menu.psm1 ----------------------------------------
# Concern : Wires the user grid context menu to the Users DataGridView.
#           The menu itself is built by New-UserContextMenu in ADDirectory.Menus.
#           This module owns the grid-side provider scriptblock, the
#           right-click row-select MouseDown handler, and the SelectionChanged
#           handler that drives the Groups pane's per-user membership view.
#           Called from Register-DirectoryTab after the grid is created.
# Load order: 13 - depends on ADDirectory.Users.Load (script scope),
#                            ADDirectory.Menus (New-UserContextMenu),
#                            ADDirectory.Groups.Load (Read-SelectedUserGroups)
# Split from: ADDirectory.Tab.psm1
#endregion

#region -- Register-UserGridMenu ----------------------------------------------
function Register-UserGridMenu {
    <#
    .SYNOPSIS
        Attaches the context menu and cell-click handler to the Users grid.
        Called once from Register-DirectoryTab after grid creation.
    #>
    param([PSCustomObject]$Context)

    if (-not $script:UserGrid) { return }

    $userGridProvider = {
        $out = @()
        if ($script:UserGrid) {
            foreach ($row in $script:UserGrid.SelectedRows) {
                $v = $row.Cells['SamAccountName'].Value
                if ($v) { $out += [PSCustomObject]@{ Sam=[string]$v; Display=[string]$row.Cells['DisplayName'].Value } }
            }
        }
        $out
    }

    $script:UserGrid.ContextMenuStrip = New-UserContextMenu -TargetProvider $userGridProvider -Context $Context

    $script:UserGrid.Add_MouseDown({
        param($s,$e)
        if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Right) { return }
        $hit = $script:UserGrid.HitTest($e.X, $e.Y)
        if ($hit.RowIndex -ge 0 -and -not $script:UserGrid.Rows[$hit.RowIndex].Selected) {
            $script:UserGrid.ClearSelection()
            $script:UserGrid.Rows[$hit.RowIndex].Selected = $true
        }
    })

    $script:UserGrid.Add_CellClick({
        param($s,$e)
        if ($e.RowIndex -lt 0) { return }
        $row = $script:UserGrid.Rows[$e.RowIndex]
        $sam = $row.Cells['SamAccountName'].Value
        if (-not $sam) { return }
        $srvParam = if ($script:DirContext.TargetDC) { @{ Server = $script:DirContext.TargetDC } } else { @{} }
        try {
            $u = Get-ADUser -Identity $sam -Properties DisplayName,SamAccountName,DistinguishedName,Enabled `
                 @srvParam -ErrorAction Stop
            if (Get-Command Set-SelectedUser -ErrorAction SilentlyContinue) { Set-SelectedUser -User $u }
        } catch {
            if (Get-Command Set-SelectedUser -ErrorAction SilentlyContinue) {
                Set-SelectedUser -User ([PSCustomObject]@{
                    SamAccountName = $sam
                    DisplayName    = $row.Cells['DisplayName'].Value
                    Name           = $sam
                })
            }
        }
    })

    # Groups pane shows membership only when exactly one user is selected.
    # SelectionChanged (not CellClick) is used here because it fires correctly
    # for click, Shift/Ctrl multi-select, and deselect-to-zero alike.
    $script:UserGrid.Add_SelectionChanged({
        if (-not (Get-Command Read-SelectedUserGroups -ErrorAction SilentlyContinue)) { return }
        $rows = @($script:UserGrid.SelectedRows)
        if ($rows.Count -eq 1) {
            $sam = $rows[0].Cells['SamAccountName'].Value
            if ($sam) { Read-SelectedUserGroups -Sam ([string]$sam) }
        } else {
            Read-SelectedUserGroups -Sam ''
        }
    })
}
#endregion

Export-ModuleMember -Function Register-UserGridMenu
