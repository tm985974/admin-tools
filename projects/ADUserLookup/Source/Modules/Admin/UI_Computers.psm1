# UI_Computers.psm1   (ADMIN TIER)
#
# Hosts the ported 'Computers' tab: Register-ComputersTab from AD Admin 1.6.1, unchanged.
# Connectivity scan grid + status cards (auto-check on row select). The grid's
# right-click menu carries LAPS, BitLocker, Sessions, Restart / Timed Restart,
# C$ share, RDP, Ping and Computer Management.
#
# Built on first view (Set-LazyTabBuild). The original registrar is handed the
# REAL main tab page, because it hooks $Tab.Parent (the main TabControl) and
# $Tab.Add_Enter exactly as it did in the original; the first visit is
# replayed for those hooks by Enable-LazyTabActivation. Shares the one AD
# $Context (Get-ADSharedContext) with every other AD tab; laid out to fill the
# window's tab page (Set-ADTabCanvas).

function New-ComputersTab {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.TabPage]$Page,
        [Parameter(Mandatory)] $App
    )
    Set-LazyTabBuild -Page $Page -App $App -LoadingText 'Loading Computers on first view...' -Build {
        param($Page, $App)
        $ctx = Get-ADSharedContext -App $App
        Set-ADTabCanvas -Context $ctx
        Register-ComputersTab -Tab $Page -Context $ctx
        # Load on the first view, not on keyboard focus (v1.2.20). Skipped when
        # the Enter handler got there first (the list is then already loaded).
        Register-ADTabFirstShow -Page $Page -Action {
            if ($script:ConnCompLoaded) { return }
            Reset-ConnCompCards
            Read-ConnComputers
        }
    }
}
