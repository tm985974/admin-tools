#region -- ADDirectory.Tree.Update.psm1 --------------------------------------
# Concern : Owns Update-OUTree. Accepts a Context, calls Get-OUTree to build
#           the node hierarchy, loads the root node into the shared TreeView
#           ($script:OUTree owned by ADDirectory.Tree.Register), and expands
#           the first level. Surfaces all errors visibly via Invoke-SetStatus
#           and a MessageBox fallback so silent failures can no longer occur.
# Load order: 6 - depends on:
#   Services.AD.Connection.Query (#3) for Get-OUTree
#   ADDirectory.Tree.Register    (#5) for $script:OUTree, Invoke-SetStatus
#endregion

#region -- Update-OUTree ------------------------------------------------------
function Update-OUTree {
    <#
    .SYNOPSIS
        Rebuilds the persistent OU TreeView from the current domain context.
        Called by:
          - Register-GlobalOUTree (initial load, end of startup)
          - Refresh Tree button click
          - Update-DirectoryTree shim (domain change)
    .PARAMETER Context
        The shared launcher $script:Context PSCustomObject.
        Must have DomainDN and TargetDC populated before this is called.
    #>
    param([PSCustomObject]$Context)

    # ------------------------------------------------------------------
    # Guard: require DomainDN
    # ------------------------------------------------------------------
    if (-not $Context -or -not $Context.DomainDN) {
        if (Get-Command Invoke-SetStatus -ErrorAction SilentlyContinue) {
            Invoke-SetStatus 'OU tree: no domain connected.' 'warn'
        }
        return
    }

    # ------------------------------------------------------------------
    # Guard: require the TreeView control to exist
    # ------------------------------------------------------------------
    if (-not $script:OUTree) {
        if (Get-Command Invoke-SetStatus -ErrorAction SilentlyContinue) {
            Invoke-SetStatus 'OU tree: TreeView control not initialised.' 'err'
        }
        return
    }

    # ------------------------------------------------------------------
    # Status: inform user a rebuild is in progress
    # ------------------------------------------------------------------
    if (Get-Command Invoke-SetStatus -ErrorAction SilentlyContinue) {
        Invoke-SetStatus "Building OU tree for $($Context.DomainDN) ..." 'info'
    }

    # Allow the UI to repaint before the blocking AD call
    try { [System.Windows.Forms.Application]::DoEvents() } catch { }

    # ------------------------------------------------------------------
    # Build the node tree
    # ------------------------------------------------------------------
    $rootNode = $null
    try {
        $server   = if ($Context.TargetDC) { $Context.TargetDC } else { '' }
        $rootNode = Get-OUTree -DomainDN $Context.DomainDN -Server $server
    } catch {
        $errMsg = $_.Exception.Message

        if (Get-Command Invoke-SetStatus -ErrorAction SilentlyContinue) {
            Invoke-SetStatus "OU tree build failed: $errMsg" 'err'
        }

        [System.Windows.Forms.MessageBox]::Show(
            "The OU tree could not be built.`n`nDomain : $($Context.DomainDN)`nDC     : $($Context.TargetDC)`n`nError  : $errMsg",
            'OU Tree Error',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null

        return
    }

    # ------------------------------------------------------------------
    # Guard: Get-OUTree returned nothing
    # ------------------------------------------------------------------
    if (-not $rootNode) {
        if (Get-Command Invoke-SetStatus -ErrorAction SilentlyContinue) {
            Invoke-SetStatus 'OU tree: Get-OUTree returned no data.' 'warn'
        }
        return
    }

    # ------------------------------------------------------------------
    # Load into TreeView
    # ------------------------------------------------------------------
    $script:OUTree.BeginUpdate()
    try {
        $script:OUTree.Nodes.Clear()
        [void]$script:OUTree.Nodes.Add($rootNode)
        $script:OUTree.Nodes[0].Expand()       # expand root so first-level OUs are visible
    } finally {
        $script:OUTree.EndUpdate()
    }

    # ------------------------------------------------------------------
    # Status: done
    # ------------------------------------------------------------------
    $ouCount = $script:OUTree.Nodes[0].Nodes.Count
    if (Get-Command Invoke-SetStatus -ErrorAction SilentlyContinue) {
        Invoke-SetStatus "OU tree loaded  ($ouCount top-level OUs)." 'ok'
    }
}
#endregion

Export-ModuleMember -Function Update-OUTree
