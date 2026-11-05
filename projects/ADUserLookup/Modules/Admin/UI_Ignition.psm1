# UI_Ignition.psm1   (ADMIN TIER)
#
# Hosts the 'Ignition' tab: low-noise Ignition gateway discovery. Built on
# first view (Set-LazyTabBuild). Shares the one AD $Context
# (Get-ADSharedContext) with every other AD tab; laid out to fill the window's
# tab page (Set-ADTabCanvas), exactly like UI_Computers.

function New-IgnitionTab {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.TabPage]$Page,
        [Parameter(Mandatory)] $App
    )
    Set-LazyTabBuild -Page $Page -App $App -LoadingText 'Loading Ignition on first view...' -Build {
        param($Page, $App)
        $ctx = Get-ADSharedContext -App $App
        Set-ADTabCanvas -Context $ctx
        Register-IgnitionTab -Tab $Page -Context $ctx
    }
}
