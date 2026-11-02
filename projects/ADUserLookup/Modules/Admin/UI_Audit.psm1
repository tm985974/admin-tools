# UI_Audit.psm1   (ADMIN TIER)
#
# Hosts the ported 'Audit' tab: Register-AuditTab from AD Admin 1.6.1, unchanged.
# The Audit Dashboard: ten report cards (stale/never-logged-in/locked-out
# users, expiring and never-expiring passwords, empty groups, disabled users
# still in groups, service accounts, stale and disabled computers).
#
# Built on first view (Set-LazyTabBuild). The original registrar is handed the
# REAL main tab page, because it hooks $Tab.Parent (the main TabControl) and
# $Tab.Add_Enter exactly as it did in the original; the first visit is
# replayed for those hooks by Enable-LazyTabActivation. Shares the one AD
# $Context (Get-ADSharedContext) with every other AD tab; laid out to fill the
# window's tab page (Set-ADTabCanvas).

function New-AuditTab {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.TabPage]$Page,
        [Parameter(Mandatory)] $App
    )
    Set-LazyTabBuild -Page $Page -App $App -LoadingText 'Loading Audit on first view...' -Build {
        param($Page, $App)
        $ctx = Get-ADSharedContext -App $App
        Set-ADTabCanvas -Context $ctx
        Register-AuditTab -Tab $Page -Context $ctx
    }
}
