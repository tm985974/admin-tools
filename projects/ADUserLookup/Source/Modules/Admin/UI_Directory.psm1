# UI_Directory.psm1   (ADMIN TIER)
#
# Hosts the ported Users tab (the original 'Directory' area: ADDirectory_* +
# the AD query/reporting services): the global OU tree on the left
# (Register-GlobalOUTree) and the Users / per-user Groups / Activity Log panes
# (Register-DirectoryTab) on the right, laid out as in the original - one page,
# no sub-tab strip.
#
# Built on first view (Set-LazyTabBuild). Uses the one shared AD $Context
# (Get-ADSharedContext), so OU / user / group selection is the same object the
# Groups, Account Management and other tabs see. Needs RSAT (ActiveDirectory
# module) and a reachable domain; if not connected, a banner says so and User
# Lookup still works.

function New-DirectoryTab {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.TabPage]$Page,
        [Parameter(Mandatory)] $App
    )
    Set-LazyTabBuild -Page $Page -App $App -LoadingText 'Loading Users from Active Directory on first view...' -Build {
        param($Page, $App)
        $treeW = 290
        $ctx = Get-ADSharedContext -App $App

        $top = 0
        if (-not (Test-ADSharedConnected)) { Add-ADNotConnectedBanner -Parent $Page; $top = 34 }
        Set-ADTabCanvas -Context $ctx -ReserveW $treeW -ReserveH $top     # fill the window beside the tree

        # left: OU tree
        $treePanel = New-Object System.Windows.Forms.Panel
        $treePanel.Location  = New-Object System.Drawing.Point(0, $top)
        $treePanel.Size      = New-Object System.Drawing.Size(($treeW - 2), $ctx.TabH)
        $treePanel.BackColor = [System.Drawing.Color]::White
        $Page.Controls.Add($treePanel)

        $sep = New-Object System.Windows.Forms.Panel
        $sep.Location  = New-Object System.Drawing.Point(($treeW - 1), $top)
        $sep.Size      = New-Object System.Drawing.Size(1, $ctx.TabH)
        $sep.BackColor = [System.Drawing.Color]::FromArgb(180, 195, 220)
        $Page.Controls.Add($sep)

        # right: Users/Groups/Log panes. Register-DirectoryTab takes a [TabPage];
        # New-EmbeddedTabPage gives it one with no tab strip (no sub-tab look).
        $tp = New-EmbeddedTabPage -Parent $Page -X $treeW -Y $top -Width $ctx.TabW -Height $ctx.TabH -Title 'Users'
        $tp.BackColor = [System.Drawing.Color]::FromArgb(235, 238, 242)

        if (Get-Command Register-DirectoryTab -ErrorAction SilentlyContinue) {
            Register-DirectoryTab -Tab $tp -Context $ctx
        }
        if (Get-Command Register-GlobalOUTree -ErrorAction SilentlyContinue) {
            try { Register-GlobalOUTree -Container $treePanel -Context $ctx }
            catch { $App.Log('WARN', 'Directory', "tree: $($_.Exception.Message)") }
        }
        # (Register-GlobalOUTree already builds the OU tree when connected - the
        #  previous extra Update-DirectoryTree here built it a second time.)
    }
}
