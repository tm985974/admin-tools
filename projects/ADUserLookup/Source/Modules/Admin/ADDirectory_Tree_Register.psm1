#region -- ADDirectory.Tree.Register.psm1 ------------------------------------
# Concern : Scaffolds the persistent OU TreeView in the launcher left column.
#           Owns all shared script-scope tree state. Wires BeforeExpand,
#           AfterSelect, MouseDown, and button events. Calls Update-OUTree
#           on first load if a domain is already connected.
#           Show-CreateGroupDialog - small standalone "enter a name" dialog
#           used by the OU folder menu's Create Group... item. Created
#           Global/Security (the common ad-hoc admin case) - not a
#           multi-field form, since the OU folder menu's job is a quick
#           create, not a full group-provisioning workflow (Batch Add
#           Groups already covers scope/category choice for bulk creation).
#           Invoke-SetStatus only updates the launcher's status bar; the
#           Activity Log panel is fed exclusively by Write-OperationLog
#           (Services.Logging) so it shows user actions only, not transient
#           status/progress messages.
# Load order: 5 - depends on Services.AD.Reporting (New-SectionPanel, New-StdButton),
#                            Services.AD.Connection.Query (Get-OUTree, Get-OUFromDN),
#                            ADDirectory.Menus (New-UserContextMenu, etc.),
#                            ADDirectory.Groups.Load (Add-CachedGroup) - soft,
#                            guarded with Get-Command, used only by
#                            Show-CreateGroupDialog
# Split from: ADDirectory.Tree.psm1
# Changes   : OU folder right-click menu ($script:TreeOUMenu) gained two new
#             items above the existing Refresh/Clear Scope pair, separated
#             by a divider:
#               'Create User...'  - sets the Create New User panel's Target
#                 OU field to the right-clicked OU's DN, then switches to
#                 the Account Management tab. Uses the exact same
#                 BFS-from-a-live-control tab-switch approach New-
#                 UserContextMenu's Clone User item already established
#                 (walk up from a control this handler genuinely owns at
#                 click time - here, $script:TreeOUMenu.SourceControl -
#                 to its Form, find the main TabControl, select the page
#                 named 'Account Management', deferred via BeginInvoke so
#                 it survives the menu closing). Duplicated rather than
#                 refactored into a shared helper, to avoid touching
#                 Clone User's own already-working inline copy.
#               'Create Group...' - opens the new Show-CreateGroupDialog for
#                 the right-clicked OU. On success, patches the Groups cache
#                 via Add-CachedGroup (same pattern Batch Add Groups already
#                 uses) and refreshes the tree's leaf list for the current
#                 OU so the new group appears immediately.
#             Both read the right-clicked OU's DN directly off
#             $script:OUTree.SelectedNode.Tag - reliable because the
#             MouseDown handler below already sets SelectedNode to the
#             right-clicked node before assigning $script:TreeOUMenu, the
#             same ordering the existing Refresh Items in this OU / Clear
#             Scope items already depend on.
#endregion

#region -- Shared script-scope state ------------------------------------------
$script:DirContext    = $null
$script:OUTree        = $null
$script:DirOUFilter   = ''   # DN of OU currently scoping grids; empty = show all
$script:TreeUserMenu  = $null
$script:TreeGroupMenu = $null
$script:TreeCompMenu  = $null
$script:TreeOUMenu    = $null
#endregion

#region -- Invoke-SetStatus ---------------------------------------------------
function Invoke-SetStatus {
    param([string]$Msg, [string]$Level = '')
    if (Get-Command Set-Status -ErrorAction SilentlyContinue) { Set-Status $Msg $Level }
}
#endregion

#region -- Show-CreateGroupDialog ----------------------------------------------
function Show-CreateGroupDialog {
    <#
    .SYNOPSIS
        Small "enter a name" dialog for creating one Global/Security group
        directly in the given OU. Used by the OU tree's folder right-click
        menu (Create Group...). Not a multi-field provisioning form - Batch
        Add Groups already covers scope/category choice for bulk creation;
        this is deliberately the quick single-group path.
    .PARAMETER OUDN
        Distinguished Name of the target OU. Required - the caller (the OU
        folder menu handler) resolves this from the right-clicked tree node.
    .PARAMETER Context
        Shared context object (TargetDC, AdminAccount, Domain).
    #>
    param(
        [Parameter(Mandatory)]
        [string]$OUDN,
        [PSCustomObject]$Context
    )
    if (-not $OUDN) { return }

    $F_UI   = New-Object System.Drawing.Font('Segoe UI', 9)
    $F_UI_B = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $F_13B  = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)

    $dlg                 = New-Object System.Windows.Forms.Form
    $dlg.Text            = 'Create Group'
    $dlg.ClientSize      = New-Object System.Drawing.Size(440, 232)
    $dlg.FormBorderStyle = 'FixedSingle'
    $dlg.MaximizeBox     = $false
    $dlg.StartPosition   = 'CenterParent'
    $dlg.BackColor       = [System.Drawing.Color]::FromArgb(235,238,242)

    $pTitle           = New-Object System.Windows.Forms.Panel
    $pTitle.Location  = New-Object System.Drawing.Point(0, 0)
    $pTitle.Size      = New-Object System.Drawing.Size(440, 48)
    $pTitle.BackColor = [System.Drawing.Color]::FromArgb(0,99,177)
    $dlg.Controls.Add($pTitle)
    $lT            = New-Object System.Windows.Forms.Label
    $lT.Text       = '   Create Group'
    $lT.Location   = New-Object System.Drawing.Point(0, 0)
    $lT.Size       = New-Object System.Drawing.Size(440, 48)
    $lT.Font       = $F_13B
    $lT.ForeColor  = [System.Drawing.Color]::White
    $lT.TextAlign  = 'MiddleLeft'
    $pTitle.Controls.Add($lT)

    $lOU           = New-Object System.Windows.Forms.Label
    $lOU.Text      = "Target OU:  $OUDN"
    $lOU.Location  = New-Object System.Drawing.Point(16, 58)
    $lOU.Size      = New-Object System.Drawing.Size(408, 32)
    $lOU.Font      = New-Object System.Drawing.Font('Segoe UI', 8)
    $lOU.ForeColor = [System.Drawing.Color]::DimGray
    $dlg.Controls.Add($lOU)

    $lName          = New-Object System.Windows.Forms.Label
    $lName.Text     = 'Group Name:'
    $lName.Location = New-Object System.Drawing.Point(16, 96)
    $lName.Size     = New-Object System.Drawing.Size(100, 20)
    $lName.Font     = $F_UI
    $dlg.Controls.Add($lName)

    $tbName             = New-Object System.Windows.Forms.TextBox
    $tbName.Location    = New-Object System.Drawing.Point(16, 118)
    $tbName.Size        = New-Object System.Drawing.Size(408, 24)
    $tbName.Font        = $F_UI
    $tbName.BorderStyle = 'FixedSingle'
    $dlg.Controls.Add($tbName)

    $lHint           = New-Object System.Windows.Forms.Label
    $lHint.Text      = 'Created as a Global Security group.'
    $lHint.Location  = New-Object System.Drawing.Point(16, 146)
    $lHint.Size      = New-Object System.Drawing.Size(408, 16)
    $lHint.Font      = New-Object System.Drawing.Font('Segoe UI', 8)
    $lHint.ForeColor = [System.Drawing.Color]::DimGray
    $dlg.Controls.Add($lHint)

    $lStatus           = New-Object System.Windows.Forms.Label
    $lStatus.Location  = New-Object System.Drawing.Point(16, 168)
    $lStatus.Size      = New-Object System.Drawing.Size(408, 20)
    $lStatus.Font      = $F_UI
    $lStatus.ForeColor = [System.Drawing.Color]::FromArgb(156,0,6)
    $dlg.Controls.Add($lStatus)

    $btnCreate           = New-Object System.Windows.Forms.Button
    $btnCreate.Text      = 'Create'
    $btnCreate.Location  = New-Object System.Drawing.Point(16, 196)
    $btnCreate.Size      = New-Object System.Drawing.Size(100, 28)
    $btnCreate.FlatStyle = 'Standard'
    $btnCreate.Font      = $F_UI_B
    $dlg.Controls.Add($btnCreate)

    $btnCancel             = New-Object System.Windows.Forms.Button
    $btnCancel.Text        = 'Cancel'
    $btnCancel.Location    = New-Object System.Drawing.Point(124, 196)
    $btnCancel.Size        = New-Object System.Drawing.Size(90, 28)
    $btnCancel.FlatStyle   = 'Standard'
    $btnCancel.Font        = $F_UI
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dlg.Controls.Add($btnCancel)
    $dlg.CancelButton = $btnCancel

    # Cross-module function calls from inside the .GetNewClosure() block
    # below are unreliable by bare name in this codebase (see
    # ADTools.DomainDefaults.Tab / ADDirectory.Menus for the fuller
    # explanation) - captured here, invoked via & inside.
    $capturedContext  = $Context
    $capturedOUDN     = $OUDN
    $addCachedGroupFn = ${function:Add-CachedGroup}
    $writeOpLogFn     = ${function:Write-OperationLog}

    $btnCreate.Add_Click({
        $name = $tbName.Text.Trim()
        if (-not $name) {
            $lStatus.Text = 'Enter a group name.'
            return
        }
        $srvParam = if ($capturedContext -and $capturedContext.TargetDC) { @{ Server = $capturedContext.TargetDC } } else { @{} }
        try {
            New-ADGroup -Name $name -GroupScope Global -GroupCategory Security -Path $capturedOUDN `
                @srvParam -ErrorAction Stop

            if ($writeOpLogFn) {
                & $writeOpLogFn -Context $capturedContext -Action 'CREATE-GROUP' -Target $name -Result 'OK' `
                    -Detail "OU=$capturedOUDN Scope=Global Category=Security"
            }
            if ($addCachedGroupFn) {
                $ouFriendly = Get-OUFromDN -DN $capturedOUDN
                & $addCachedGroupFn -Group ([PSCustomObject]@{
                    Name              = $name
                    GroupType         = 'Security'
                    Scope             = 'Global'
                    Description       = ''
                    ManagedBy         = ''
                    Created           = (Get-Date -Format 'yyyy-MM-dd')
                    OU                = $ouFriendly
                    DistinguishedName = "CN=$name,$capturedOUDN"
                })
            }
            # Refresh this OU's leaf list so the new group appears in the
            # tree immediately, same as Batch Add Groups' own after-create
            # refresh expectation.
            if (Get-Command Update-TreeLeavesForSelection -ErrorAction SilentlyContinue) { Update-TreeLeavesForSelection }

            $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $dlg.Close()
        } catch {
            $lStatus.Text = "Failed: $($_.Exception.Message)"
        }
    }.GetNewClosure())

    [void]$dlg.ShowDialog()
}
#endregion

#region -- Register-GlobalOUTree ----------------------------------------------
function Register-GlobalOUTree {
    <#
    .SYNOPSIS
        Builds the persistent OU tree in the launcher's left column panel.
        Creates the TreeView, wires BeforeExpand for lazy leaf loading,
        wires AfterSelect for OU scope + object context, builds three
        leaf context menus (user / group / computer), and does the initial
        tree build if a domain is already connected.
        Called ONCE from the launcher after Initialize-AllTabs.
    #>
    param(
        [System.Windows.Forms.Control]$Container,
        [PSCustomObject]$Context
    )
    $script:DirContext = $Context

    $PAD    = 6
    $F_UI   = New-Object System.Drawing.Font('Segoe UI', 9)
    $F_UI_B = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)

    $cW = $Container.ClientSize.Width
    $cH = $Container.ClientSize.Height

    $BTN_SEC_OUTER = 87
    $TREE_SECT_H   = $cH - $PAD - $BTN_SEC_OUTER - $PAD
    $treeSecW      = $cW - ($PAD * 2)

    $ouSection = New-SectionPanel -Parent $Container -Title 'OU Tree' `
        -X $PAD -Y $PAD -W $treeSecW -H $TREE_SECT_H

    $script:OUTree               = New-Object System.Windows.Forms.TreeView
    $script:OUTree.Location      = New-Object System.Drawing.Point(0, 0)
    $script:OUTree.Size          = $ouSection.ClientSize
    $script:OUTree.Font          = $F_UI
    $script:OUTree.BackColor     = [System.Drawing.Color]::White
    $script:OUTree.BorderStyle   = 'None'
    $script:OUTree.ShowLines     = $true
    $script:OUTree.ShowPlusMinus = $true
    $script:OUTree.HideSelection = $false
    $ouSection.Controls.Add($script:OUTree)

    $btnSecY = $PAD + $TREE_SECT_H + $PAD
    $halfW   = [int](($treeSecW - 14) / 2) - 2
    $btnSec  = New-SectionPanel -Parent $Container -Title '' `
        -X $PAD -Y $btnSecY -W $treeSecW -ContentH 60
    $btnRefreshTree = New-StdButton -Text 'Refresh Tree'          -X 4           -Y 2  -W $halfW           -H 26 -Parent $btnSec
    $btnClearOU     = New-StdButton -Text 'Clear Scope'           -X ($halfW+8)  -Y 2  -W $halfW           -H 26 -Parent $btnSec
    $btnReload      = New-StdButton -Text 'Reload Directory Data' -X 4           -Y 32 -W ($treeSecW - 12) -H 26 -Parent $btnSec

    # -------------------------------------------------------------------------
    # Leaf context menu providers
    # -------------------------------------------------------------------------
    $treeUserProvider = {
        $out = @()
        if ($script:OUTree) {
            $n = $script:OUTree.SelectedNode
            if ($n -and $n.Tag -isnot [string] -and $n.Tag.Kind -eq 'User') {
                $out = @([PSCustomObject]@{ Sam=[string]$n.Tag.Id; Display=[string]$n.Tag.Display })
            }
        }
        $out
    }
    $treeGroupProvider = {
        $out = @()
        if ($script:OUTree) {
            $n = $script:OUTree.SelectedNode
            if ($n -and $n.Tag -isnot [string] -and $n.Tag.Kind -eq 'Group') {
                $out = @([PSCustomObject]@{ Name=[string]$n.Tag.Id; DN=[string]$n.Tag.DN })
            }
        }
        $out
    }
    $treeCompProvider = {
        $out = @()
        if ($script:OUTree) {
            $n = $script:OUTree.SelectedNode
            if ($n -and $n.Tag -isnot [string] -and $n.Tag.Kind -eq 'Computer') {
                $out = @([PSCustomObject]@{ Name=[string]$n.Tag.Id })
            }
        }
        $out
    }

    $script:TreeUserMenu  = New-UserContextMenu     -TargetProvider $treeUserProvider  -Context $Context
    $script:TreeGroupMenu = New-GroupContextMenu    -TargetProvider $treeGroupProvider -Context $Context
    $script:TreeCompMenu  = New-ComputerContextMenu -TargetProvider $treeCompProvider -Context $Context

    $script:TreeOUMenu      = New-Object System.Windows.Forms.ContextMenuStrip
    $script:TreeOUMenu.Font = $F_UI

    $miOUCreateUser      = New-Object System.Windows.Forms.ToolStripMenuItem
    $miOUCreateUser.Text = 'Create User...'
    $miOUCreateUser.Add_Click({
        $node = $script:OUTree.SelectedNode
        if (-not $node -or $node.Tag -isnot [string] -or $node.Tag -eq '__SENTINEL__') { return }
        $ouDN = [string]$node.Tag

        if (-not $script:UANewOUBox) {
            [System.Windows.Forms.MessageBox]::Show('Create User module not loaded.','Create User','OK','Warning')
            return
        }
        $script:UANewOUBox.Text = $ouDN
        if ($script:UAOUHint) { $script:UAOUHint.Visible = $false }

        # Switch to the Account Management tab - same BFS-from-a-live-control
        # approach New-UserContextMenu's Clone User item already established
        # (see that function's own comment for the full rationale). Walk up
        # from a control this handler genuinely owns at click time -
        # $script:TreeOUMenu.SourceControl, set by WinForms to $script:OUTree
        # since that is what just displayed this menu - to its Form, find the
        # main TabControl, select the page named 'Account Management',
        # deferred via BeginInvoke so the switch survives the menu closing
        # and restoring focus to the tree (which would otherwise snap the
        # selection back to this tab).
        $navForm = $null
        $navSrc  = $script:TreeOUMenu.SourceControl
        if ($navSrc) { $navForm = $navSrc.FindForm() }
        if (-not $navForm) { $navForm = [System.Windows.Forms.Form]::ActiveForm }

        $navDone = $false
        if ($navForm) {
            $navTabCtl = $null
            $navQueue  = New-Object System.Collections.Generic.Queue[System.Windows.Forms.Control]
            foreach ($navChild in $navForm.Controls) { $navQueue.Enqueue($navChild) }
            while ($navQueue.Count -gt 0) {
                $navCtl = $navQueue.Dequeue()
                if ($navCtl -is [System.Windows.Forms.TabControl]) { $navTabCtl = $navCtl; break }
                foreach ($navChild in $navCtl.Controls) { $navQueue.Enqueue($navChild) }
            }
            if ($navTabCtl) {
                foreach ($navPage in $navTabCtl.TabPages) {
                    if ((([string]$navPage.Text).Trim()) -eq 'Account Management') {
                        $navTargetCtl = $navTabCtl
                        $navTargetTab = $navPage
                        $navSwitch = { $navTargetCtl.SelectedTab = $navTargetTab }.GetNewClosure()
                        [void]$navTargetCtl.BeginInvoke([System.Windows.Forms.MethodInvoker]$navSwitch)
                        $navDone = $true
                        break
                    }
                }
            }
        }
        if (-not $navDone) {
            [System.Windows.Forms.MessageBox]::Show(
                'Target OU was set, but the Account Management tab could not be located to switch to.',
                'Create User','OK','Warning')
        }
    })
    [void]$script:TreeOUMenu.Items.Add($miOUCreateUser)

    $miOUCreateGroup      = New-Object System.Windows.Forms.ToolStripMenuItem
    $miOUCreateGroup.Text = 'Create Group...'
    $miOUCreateGroup.Add_Click({
        $node = $script:OUTree.SelectedNode
        if (-not $node -or $node.Tag -isnot [string] -or $node.Tag -eq '__SENTINEL__') { return }
        $ouDN = [string]$node.Tag
        if (Get-Command Show-CreateGroupDialog -ErrorAction SilentlyContinue) {
            Show-CreateGroupDialog -OUDN $ouDN -Context $script:DirContext
        } else {
            [System.Windows.Forms.MessageBox]::Show('Create Group dialog not loaded.','Create Group','OK','Warning')
        }
    })
    [void]$script:TreeOUMenu.Items.Add($miOUCreateGroup)

    [void]$script:TreeOUMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $miOURefresh            = New-Object System.Windows.Forms.ToolStripMenuItem
    $miOURefresh.Text       = 'Refresh Items in this OU'
    $miOURefresh.Add_Click({ Update-TreeLeavesForSelection })
    [void]$script:TreeOUMenu.Items.Add($miOURefresh)
    $miOUClear              = New-Object System.Windows.Forms.ToolStripMenuItem
    $miOUClear.Text         = 'Clear Scope (show all)'
    $miOUClear.Add_Click({
        if ($script:OUTree.Nodes.Count -gt 0) { $script:OUTree.SelectedNode = $script:OUTree.Nodes[0] }
    })
    [void]$script:TreeOUMenu.Items.Add($miOUClear)

    # -------------------------------------------------------------------------
    # AfterSelect: scope grids to selected OU or set selected object on leaf
    # -------------------------------------------------------------------------
    $script:OUTree.Add_AfterSelect({
        $node = $script:OUTree.SelectedNode
        if (-not $node) { return }
        $tag  = $node.Tag

        if ($tag -eq '__SENTINEL__') { return }

        if ($tag -is [string]) {
            $ouDN   = [string]$tag
            $isRoot = ($ouDN -eq $script:DirContext.DomainDN)
            if (Get-Command Set-SelectedOU -ErrorAction SilentlyContinue) {
                if ($isRoot) { Set-SelectedOU -Name '' -DN '' }
                else         { Set-SelectedOU -Name $node.Text -DN $ouDN }
            }
            $script:DirOUFilter = if ($isRoot) { '' } else { $ouDN }
        } else {
            $parentDN = if ($node.Parent) { [string]$node.Parent.Tag } else { '' }
            $isRoot   = ($parentDN -eq $script:DirContext.DomainDN -or -not $parentDN)
            if (Get-Command Set-SelectedOU -ErrorAction SilentlyContinue) {
                if ($isRoot) { Set-SelectedOU -Name '' -DN '' }
                elseif ($node.Parent) { Set-SelectedOU -Name $node.Parent.Text -DN $parentDN }
            }
            $script:DirOUFilter = if ($isRoot) { '' } else { $parentDN }

            if ($tag.Kind -eq 'User') {
                $uObj = [PSCustomObject]@{
                    SamAccountName    = [string]$tag.Id
                    DisplayName       = [string]$tag.Display
                    DistinguishedName = [string]$tag.DN
                }
                if (Get-Command Set-SelectedUser -ErrorAction SilentlyContinue) { Set-SelectedUser -User $uObj }
            } elseif ($tag.Kind -eq 'Group') {
                $gObj = [PSCustomObject]@{ Name=[string]$tag.Id; DistinguishedName=[string]$tag.DN }
                if (Get-Command Set-SelectedGroup -ErrorAction SilentlyContinue) { Set-SelectedGroup -Group $gObj }
            } elseif ($tag.Kind -eq 'Computer') {
                $cObj = [PSCustomObject]@{ Name=[string]$tag.Id; DistinguishedName=[string]$tag.DN }
                if (Get-Command Set-SelectedComputer -ErrorAction SilentlyContinue) { Set-SelectedComputer -Comp $cObj }
            }
        }

        if (Get-Command Update-UserGrid  -ErrorAction SilentlyContinue) { Update-UserGrid  }
        if (Get-Command Update-GroupGrid -ErrorAction SilentlyContinue) { Update-GroupGrid }
        if (Get-Command Update-CompGrid  -ErrorAction SilentlyContinue) { Update-CompGrid  }
    })

    # -------------------------------------------------------------------------
    # BeforeExpand: lazy leaf loading
    # -------------------------------------------------------------------------
    $script:OUTree.Add_BeforeExpand({
        param($s, $e)
        Load-OUNodeLeaves -Node $e.Node
    })

    # -------------------------------------------------------------------------
    # MouseDown: assign correct leaf context menu before right-click shows
    # -------------------------------------------------------------------------
    $script:OUTree.Add_MouseDown({
        param($s, $e)
        if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Right) { return }
        $node = $script:OUTree.GetNodeAt($e.X, $e.Y)
        if (-not $node) { $script:OUTree.ContextMenuStrip = $null; return }
        $script:OUTree.SelectedNode = $node
        $tag = $node.Tag
        if ($tag -is [string]) {
            $script:OUTree.ContextMenuStrip = if ($tag -eq '__SENTINEL__') { $null } else { $script:TreeOUMenu }
        } elseif ($tag -and $tag.Kind -eq 'User')     { $script:OUTree.ContextMenuStrip = $script:TreeUserMenu  }
          elseif ($tag -and $tag.Kind -eq 'Group')    { $script:OUTree.ContextMenuStrip = $script:TreeGroupMenu }
          elseif ($tag -and $tag.Kind -eq 'Computer') { $script:OUTree.ContextMenuStrip = $script:TreeCompMenu  }
          else                                         { $script:OUTree.ContextMenuStrip = $null }
    })

    # -------------------------------------------------------------------------
    # Button events
    # -------------------------------------------------------------------------
    $btnRefreshTree.Add_Click({ Update-OUTree -Context $script:DirContext })

    $btnClearOU.Add_Click({
        if ($script:OUTree.Nodes.Count -gt 0) { $script:OUTree.SelectedNode = $script:OUTree.Nodes[0] }
    })

    $btnReload.Add_Click({
        if (Get-Command Read-DirectoryUsers     -ErrorAction SilentlyContinue) { Read-DirectoryUsers     }
        if (Get-Command Read-DirectoryComputers -ErrorAction SilentlyContinue) { Read-DirectoryComputers }
        # Groups pane shows the selected user's membership, not all domain
        # groups (see ADDirectory.Users.Menu / ADDirectory.Groups.Load).
        # Re-resolve from current selection rather than calling the legacy
        # Read-DirectoryGroups, which would wipe that view back to "all groups".
        if (Get-Command Read-SelectedUserGroups -ErrorAction SilentlyContinue) {
            $sam = ''
            if ($script:UserGrid -and @($script:UserGrid.SelectedRows).Count -eq 1) {
                $sam = [string]@($script:UserGrid.SelectedRows)[0].Cells['SamAccountName'].Value
            }
            Read-SelectedUserGroups -Sam $sam
        }
    })

    if ($Context.DomainDN) { Update-OUTree -Context $Context }
}
#endregion

Export-ModuleMember -Function `
    Invoke-SetStatus, `
    Show-CreateGroupDialog, `
    Register-GlobalOUTree
