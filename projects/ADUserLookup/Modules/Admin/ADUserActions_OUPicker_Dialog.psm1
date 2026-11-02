#region -- ADUserActions.OUPicker.Dialog.psm1 ---------------------------------
# Concern : Show-OUPicker - modal OU tree picker dialog. Returns the selected
#           OU distinguished name, or $null if cancelled.
# Load order: 30 - depends on Services.AD.Connection.Query (Get-OUTree,
#                                                            Get-ChildOrganizationalUnits,
#                                                            Get-OUDirectObjects),
#                            Services.AD.Reporting (New-StdButton)
# Split from: ADUserActions.psm1
# Changes   : BUG FIX - Get-OUTree (Services.AD.Connection.Query) was changed
#             to build lazily: it now returns only the domain root's
#             immediate child OUs, with each child OU carrying a placeholder
#             "sentinel" node so it shows an expand arrow; deeper levels are
#             meant to be filled in on BeforeExpand by Load-OUNodeLeaves
#             (ADDirectory.Tree.LoadChildren). This dialog builds its own
#             separate TreeView from the same Get-OUTree call but never wired
#             a BeforeExpand handler, so expanding any OU here just revealed
#             the empty sentinel placeholder instead of real sub-OUs -
#             clicking that placeholder could even return the literal string
#             "__SENTINEL__" as a selected DN, since the old enable-check
#             only tested for a non-null Tag. Fixed by wiring BeforeExpand to
#             call Load-OUNodeLeaves (same handler the persistent left-column
#             tree uses), and by explicitly excluding the sentinel from the
#             Select button's enabled state and from a successful Select
#             click.
#endregion

#region -- Show-OUPicker ------------------------------------------------------
function Show-OUPicker {
    param([PSCustomObject]$Context)
    $F_UI   = New-Object System.Drawing.Font('Segoe UI', 9)
    $F_UI_B = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $F_13B  = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)

    $dlg                  = New-Object System.Windows.Forms.Form
    $dlg.Text             = 'Select OU'
    $dlg.ClientSize       = New-Object System.Drawing.Size(480, 460)
    $dlg.FormBorderStyle  = 'FixedSingle'
    $dlg.MaximizeBox      = $false
    $dlg.StartPosition    = 'CenterParent'
    $dlg.BackColor        = [System.Drawing.Color]::FromArgb(235,238,242)

    $pTitle               = New-Object System.Windows.Forms.Panel
    $pTitle.Dock          = 'Top'; $pTitle.Height = 48
    $pTitle.BackColor     = [System.Drawing.Color]::FromArgb(0,99,177)
    $dlg.Controls.Add($pTitle)
    $lT                   = New-Object System.Windows.Forms.Label
    $lT.Text              = '   Select Target OU'
    $lT.Dock              = 'Fill'; $lT.Font = $F_13B
    $lT.ForeColor         = [System.Drawing.Color]::White
    $lT.TextAlign         = 'MiddleLeft'
    $pTitle.Controls.Add($lT)

    $tree                 = New-Object System.Windows.Forms.TreeView
    $tree.Location        = New-Object System.Drawing.Point(12, 60)
    $tree.Size            = New-Object System.Drawing.Size(454, 340)
    $tree.Font            = $F_UI
    $tree.BackColor       = [System.Drawing.Color]::White
    $tree.BorderStyle     = 'FixedSingle'
    $dlg.Controls.Add($tree)

    $btnOK                = New-StdButton -Text 'Select' -X 264 -Y 412 -W 90 -H 30 -Parent $dlg
    $btnOK.Font           = $F_UI_B
    $btnOK.Enabled        = $false
    $btnCancel            = New-StdButton -Text 'Cancel' -X 362 -Y 412 -W 90 -H 30 -Parent $dlg

    $script:OUPickResult  = $null

    # This dialog's tree is independent of the persistent left-column tree,
    # but Load-OUNodeLeaves (ADDirectory.Tree.LoadChildren) resolves its
    # server from $script:DirContext.TargetDC, which is set once by
    # Register-GlobalOUTree at startup and shared script-scope-wide - so it
    # already resolves correctly for this dialog too without any extra
    # wiring, as long as a domain has been connected (which Show-OUPicker
    # already requires via $Context.DomainDN below).
    $dlg.Add_Shown({
        if ($Context.DomainDN) {
            $root = Get-OUTree -DomainDN $Context.DomainDN -Server $Context.TargetDC
            [void]$tree.Nodes.Add($root)
            $tree.Nodes[0].Expand()
        }
    })

    # BeforeExpand: lazily fill in child OUs (and replace the sentinel
    # placeholder), same handler the persistent left-column tree uses.
    # Without this, every node's sentinel placeholder is all that ever shows.
    $tree.Add_BeforeExpand({
        param($s, $e)
        if (Get-Command Load-OUNodeLeaves -ErrorAction SilentlyContinue) {
            Load-OUNodeLeaves -Node $e.Node
        }
    })

    $tree.Add_AfterSelect({
        $sel = $tree.SelectedNode
        $btnOK.Enabled = ($null -ne $sel -and $null -ne $sel.Tag -and [string]$sel.Tag -ne '__SENTINEL__')
    })
    $btnOK.Add_Click({
        if ($tree.SelectedNode -and $tree.SelectedNode.Tag -and [string]$tree.SelectedNode.Tag -ne '__SENTINEL__') {
            $script:OUPickResult = [string]$tree.SelectedNode.Tag
            $dlg.DialogResult    = [System.Windows.Forms.DialogResult]::OK
            $dlg.Close()
        }
    })
    $btnCancel.Add_Click({
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $dlg.Close()
    })
    $dlg.ShowDialog() | Out-Null
    return $script:OUPickResult
}
#endregion

Export-ModuleMember -Function Show-OUPicker
