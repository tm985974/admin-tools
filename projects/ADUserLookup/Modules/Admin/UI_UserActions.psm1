# UI_UserActions.psm1   (ADMIN TIER)
#
# Hosts the ported 'Account Management' tab: Register-UserActionsTab from AD Admin 1.6.1, unchanged.
# Create User (with clone, paste import queue, OU picker, group picks, generated
# password) and the Action Results log. Offboarding lives on Bulk Operations,
# as in the original.
#
# Built on first view (Set-LazyTabBuild). The original registrar is handed the
# REAL main tab page, because it hooks $Tab.Parent (the main TabControl) and
# $Tab.Add_Enter exactly as it did in the original; the first visit is
# replayed for those hooks by Enable-LazyTabActivation. Shares the one AD
# $Context (Get-ADSharedContext) with every other AD tab; laid out to fill the
# window's tab page (Set-ADTabCanvas).

function New-UserActionsTab {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.TabPage]$Page,
        [Parameter(Mandatory)] $App
    )
    Set-LazyTabBuild -Page $Page -App $App -LoadingText 'Loading Account Management on first view...' -Build {
        param($Page, $App)
        $ctx = Get-ADSharedContext -App $App
        Set-ADTabCanvas -Context $ctx
        Register-UserActionsTab -Tab $Page -Context $ctx
    }
}
