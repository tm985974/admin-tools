# UI_Groups.psm1   (ADMIN TIER)
#
# Standalone Groups tab (all-domain group management) - the ported
# Register-GroupsTab, which in the original is its own top-level tab separate
# from the Users tab. One page, no sub-tab strip.
#
# Built on first view (Set-LazyTabBuild) and shares the one AD $Context
# (Get-ADSharedContext) with the other AD tabs. Needs RSAT + a reachable domain.

function New-GroupsTab {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.TabPage]$Page,
        [Parameter(Mandatory)] $App
    )
    Set-LazyTabBuild -Page $Page -App $App -LoadingText 'Loading Groups from Active Directory on first view...' -Build {
        param($Page, $App)
        $ctx = Get-ADSharedContext -App $App

        $top = 0
        if (-not (Test-ADSharedConnected)) { Add-ADNotConnectedBanner -Parent $Page; $top = 34 }
        Set-ADTabCanvas -Context $ctx -ReserveH $top

        # Register-GroupsTab takes a [TabPage]; New-EmbeddedTabPage gives it one
        # with no tab strip (no sub-tab look).
        $tp = New-EmbeddedTabPage -Parent $Page -X 0 -Y $top -Width $ctx.TabW -Height $ctx.TabH -Title 'Groups'
        $tp.BackColor = [System.Drawing.Color]::FromArgb(235, 238, 242)

        if (Get-Command Register-GroupsTab -ErrorAction SilentlyContinue) {
            Register-GroupsTab -Tab $tp -Context $ctx
        } else {
            $l = New-Object System.Windows.Forms.Label; $l.Text = 'Register-GroupsTab not available.'; $l.Dock = 'Fill'; $l.Padding = '8,8,8,8'
            $tp.Controls.Add($l)
        }
    }
}
