#region -- ADDirectory.Tree.LoadChildren.psm1 --------------------------------
# Concern : Lazy leaf population. Load-OUNodeLeaves is called from BeforeExpand
#           (wired in ADDirectory.Tree.Register). Replaces the sentinel child
#           with real child-OU nodes AND user/group/computer object nodes at
#           OneLevel depth. Update-TreeLeavesForSelection refreshes leaf
#           objects after a write operation.
# Load order: 7 - depends on ADDirectory.Tree.Register (script scope),
#                            Services.AD.Connection.Query (Get-ChildOrganizationalUnits,
#                                                           Get-OUDirectObjects)
# Split from: ADDirectory.Tree.psm1
# Changes   : Load-OUNodeLeaves now also fetches the expanding node's own
#             child OUs (via Get-ChildOrganizationalUnits, one OneLevel query)
#             and gives each a sentinel, completing the lazy OU tree - child
#             OU nodes used to be built eagerly for the whole domain by the
#             old Get-OUTree; now every level below the domain root is loaded
#             on demand, one expand at a time. Direct object leaves
#             (users/groups/computers) are still fetched the same way as
#             before via Get-OUDirectObjects. Update-TreeLeavesForSelection is
#             unchanged - it only ever refreshed leaf objects (not child OUs)
#             and continues to do so.
#             DIAGNOSTICS: Load-OUNodeLeaves logs (via the shared
#             Write-ModuleDebugLog, defined in _AD-Admin.ps1) every guard it
#             hits, the DN/server it resolves, and the final child-node count.
#             BUG FIX: every new TreeNode built here set a ".Font" property,
#             which does not exist on System.Windows.Forms.TreeNode (the real
#             property is ".NodeFont") - this threw a RuntimeException the
#             instant the first child node was created on any expand that
#             actually had child OUs or direct objects, silently aborting
#             that whole foreach loop (caught by the surrounding try/catch)
#             and leaving the node with 0 children even though AD had
#             returned real data. Confirmed directly from the diagnostics log
#             ("The property 'Font' cannot be found on this object") - this
#             is what made every OU with real content look empty on expand.
#             Fixed by using .NodeFont instead of .Font on every TreeNode
#             created in this file (Load-OUNodeLeaves and
#             Update-TreeLeavesForSelection).
#endregion

#region -- Write-TreeDebugLog (private helper) ---------------------------------
function Write-TreeDebugLog {
    param([string]$Text)
    if (Get-Command Write-ModuleDebugLog -ErrorAction SilentlyContinue) {
        Write-ModuleDebugLog "[Tree] $Text"
    }
}
#endregion

#region -- Load-OUNodeLeaves --------------------------------------------------
function Load-OUNodeLeaves {
    <#
    .SYNOPSIS
        Called from BeforeExpand. If the node has a sentinel child at index 0,
        removes it and lazily populates the node with:
          1. its own child OU nodes (each carrying its own sentinel, so the
             tree stays lazy at every depth), via Get-ChildOrganizationalUnits
          2. its direct object leaves (users/groups/computers), via
             Get-OUDirectObjects (OneLevel)
        Nodes that have already been expanded once (no sentinel present) are
        left untouched.
    #>
    param([System.Windows.Forms.TreeNode]$Node)
    if (-not $Node) { Write-TreeDebugLog "Load-OUNodeLeaves: called with null Node - returning"; return }

    Write-TreeDebugLog "Load-OUNodeLeaves: entered for node Text='$($Node.Text)' Tag='$($Node.Tag)' Nodes.Count=$($Node.Nodes.Count)"

    if ($Node.Nodes.Count -eq 0) {
        Write-TreeDebugLog "Load-OUNodeLeaves: node has 0 children (no sentinel present) - nothing to do, returning"
        return
    }
    if ($Node.Nodes[0].Name -ne '__SENTINEL__') {
        Write-TreeDebugLog "Load-OUNodeLeaves: first child Name='$($Node.Nodes[0].Name)' is not the sentinel - already loaded, returning"
        return
    }

    [void]$Node.Nodes.RemoveAt(0)

    $ouDN = [string]$Node.Tag
    if (-not $ouDN -or $ouDN -eq '__SENTINEL__') {
        Write-TreeDebugLog "Load-OUNodeLeaves: node Tag is blank/sentinel ('$ouDN') - cannot resolve a DN, returning with 0 children"
        return
    }
    $srv  = if ($script:DirContext) { $script:DirContext.TargetDC } else { '' }
    Write-TreeDebugLog "Load-OUNodeLeaves: resolved ouDN='$ouDN' srv='$srv' (script:DirContext present = $([bool]$script:DirContext))"

    $C_DIM = [System.Drawing.Color]::FromArgb(160, 160, 160)
    $F_UI  = New-Object System.Drawing.Font('Segoe UI', 9)

    # -- Child OUs (lazy: one OneLevel query for this node only, not the
    #    whole subtree) - completes the deferred load Get-OUTree started
    #    at the domain root. --------------------------------------------------
    $childOUCount = 0
    if (Get-Command Get-ChildOrganizationalUnits -ErrorAction SilentlyContinue) {
        try {
            $childOUs = Get-ChildOrganizationalUnits -ParentDN $ouDN -Server $srv
            foreach ($cou in $childOUs) {
                $ouNode          = New-Object System.Windows.Forms.TreeNode
                $ouNode.Text     = $cou.Name
                $ouNode.Tag      = $cou.DN
                $ouNode.Name     = $cou.DN
                $ouNode.NodeFont = $F_UI

                $sentinel      = New-Object System.Windows.Forms.TreeNode
                $sentinel.Text = ''; $sentinel.Name = '__SENTINEL__'; $sentinel.Tag = '__SENTINEL__'
                [void]$ouNode.Nodes.Insert(0, $sentinel)

                [void]$Node.Nodes.Add($ouNode)
                $childOUCount++
            }
        } catch {
            Write-TreeDebugLog "Load-OUNodeLeaves: Get-ChildOrganizationalUnits THREW [$($_.Exception.GetType().FullName)] $($_.Exception.Message)"
        }
    } else {
        Write-TreeDebugLog "Load-OUNodeLeaves: Get-ChildOrganizationalUnits command not found"
    }

    # -- Direct objects (users/groups/computers) in this OU ------------------
    $objCount = 0
    try {
        $objs = Get-OUDirectObjects -OUDN $ouDN -Server $srv
        foreach ($o in $objs) {
            $prefix = switch ($o.Kind) {
                'User'     { '[U] ' }
                'Group'    { '[G] ' }
                'Computer' { '[C] ' }
                default    { '' }
            }
            $leaf          = New-Object System.Windows.Forms.TreeNode
            $leaf.Text     = "$prefix$($o.Display)"
            $leaf.Tag      = $o
            $leaf.Name     = [string]$o.DN
            $leaf.NodeFont = $F_UI
            if (-not $o.Enabled) { $leaf.ForeColor = $C_DIM }
            [void]$Node.Nodes.Add($leaf)
            $objCount++
        }
    } catch {
        Write-TreeDebugLog "Load-OUNodeLeaves: Get-OUDirectObjects THREW [$($_.Exception.GetType().FullName)] $($_.Exception.Message)"
    }

    Write-TreeDebugLog "Load-OUNodeLeaves: finished for '$ouDN' - added $childOUCount child OU(s) + $objCount object(s) = $($Node.Nodes.Count) total child node(s)"
}
#endregion

#region -- Update-TreeLeavesForSelection --------------------------------------
function Update-TreeLeavesForSelection {
    <#
    .SYNOPSIS
        After a write operation refreshes the leaf objects under the currently
        selected tree node's OU. Only triggers if leaves have already been
        loaded (no sentinel present). Preserves child OU nodes - it never
        touches OU structure, only the user/group/computer leaves directly
        inside the selected OU.
    #>
    if (-not $script:OUTree) { return }
    $node = $script:OUTree.SelectedNode
    if (-not $node) { return }

    $target = $null
    if ($node.Tag -is [string] -and $node.Tag -ne '__SENTINEL__') {
        $target = $node
    } elseif ($node.Parent -and $node.Parent.Tag -is [string]) {
        $target = $node.Parent
    }
    if (-not $target) { return }

    $hasSentinel = $false
    foreach ($ch in $target.Nodes) {
        if ($ch.Name -eq '__SENTINEL__') { $hasSentinel = $true; break }
    }
    if ($hasSentinel) { return }

    for ($i = $target.Nodes.Count - 1; $i -ge 0; $i--) {
        if ($target.Nodes[$i].Tag -isnot [string]) { $target.Nodes.RemoveAt($i) }
    }

    $ouDN  = [string]$target.Tag
    $srv   = if ($script:DirContext) { $script:DirContext.TargetDC } else { '' }
    $C_DIM = [System.Drawing.Color]::FromArgb(160, 160, 160)
    $F_UI  = New-Object System.Drawing.Font('Segoe UI', 9)
    try {
        $objs = Get-OUDirectObjects -OUDN $ouDN -Server $srv
        foreach ($o in $objs) {
            $prefix        = switch ($o.Kind) { 'User' {'[U] '} 'Group' {'[G] '} 'Computer' {'[C] '} default {''} }
            $leaf          = New-Object System.Windows.Forms.TreeNode
            $leaf.Text     = "$prefix$($o.Display)"; $leaf.Tag = $o
            $leaf.Name     = [string]$o.DN; $leaf.NodeFont = $F_UI
            if (-not $o.Enabled) { $leaf.ForeColor = $C_DIM }
            [void]$target.Nodes.Add($leaf)
        }
    } catch { }
}
#endregion

Export-ModuleMember -Function `
    Load-OUNodeLeaves, `
    Update-TreeLeavesForSelection
