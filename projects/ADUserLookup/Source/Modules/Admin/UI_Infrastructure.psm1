# UI_Infrastructure.psm1   (ADMIN TIER)
#
# Hosts the ported 'Infrastructure' tab: Register-InfrastructureTab from AD Admin 1.6.1, unchanged.
# Forest / Domain Level, Trusts, DC Health, Privileged Accounts and GPO Scope.
# Each sub-tab loads on its first view; DC Health on the first visit.
#
# Built on first view (Set-LazyTabBuild). The original registrar is handed the
# REAL main tab page, because it hooks $Tab.Parent (the main TabControl) and
# $Tab.Add_Enter exactly as it did in the original; the first visit is
# replayed for those hooks by Enable-LazyTabActivation. Shares the one AD
# $Context (Get-ADSharedContext) with every other AD tab; laid out to fill the
# window's tab page (Set-ADTabCanvas).

function New-InfrastructureTab {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.TabPage]$Page,
        [Parameter(Mandatory)] $App
    )
    Set-LazyTabBuild -Page $Page -App $App -LoadingText 'Loading Infrastructure on first view...' -Build {
        param($Page, $App)
        $ctx = Get-ADSharedContext -App $App
        Set-ADTabCanvas -Context $ctx
        Register-InfrastructureTab -Tab $Page -Context $ctx
    }
}
