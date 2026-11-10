# UI_BulkOps.psm1   (ADMIN TIER)
#
# Hosts the ported 'Bulk Operations' tab: Register-BulkOpsTab from AD Admin 1.6.1, unchanged.
# Batch Delete, Bulk Add Users (CSV onboarding), Bulk Add Groups, Add Users to
# Groups and Offboard, plus the shared Activity Log strip.
#
# Built on first view (Set-LazyTabBuild). The original registrar is handed the
# REAL main tab page, because it hooks $Tab.Parent (the main TabControl) and
# $Tab.Add_Enter exactly as it did in the original; the first visit is
# replayed for those hooks by Enable-LazyTabActivation. Shares the one AD
# $Context (Get-ADSharedContext) with every other AD tab; laid out to fill the
# window's tab page (Set-ADTabCanvas).

function New-BulkOpsTab {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.TabPage]$Page,
        [Parameter(Mandatory)] $App
    )
    Set-LazyTabBuild -Page $Page -App $App -LoadingText 'Loading Bulk Operations on first view...' -Build {
        param($Page, $App)
        $ctx = Get-ADSharedContext -App $App
        Set-ADTabCanvas -Context $ctx
        Register-BulkOpsTab -Tab $Page -Context $ctx
    }
}
