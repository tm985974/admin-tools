#region -- ADComputers.Register-ComputersTab.psm1 ----------------------------
# Concern : Register-ComputersTab - builds the Computers tab content directly
#           (status cards, AD details, whole-domain grid) by calling
#           Build-ConnectivityTab against the main Computers tab page. Sets
#           $script:CompCtx, $script:_TW, $script:_TH.
# Load order: 88 - depends on ADComputers.Connectivity.TestPort (script scope),
#                            ADComputers.Connectivity.Tab (Build-ConnectivityTab)
# Split from: ADComputers.Tab.psm1
# Changes   : Removed the BitLocker and LAPS sub-tabs and the sub-TabControl
#             container that hosted all three. BitLocker/LAPS lookups now
#             live on the Computers grid's right-click menu (Show-
#             BitLockerDialog / Show-LAPSDialog, ADDirectory.Menus) instead
#             of separate sub-tabs. Build-ConnectivityTab is now called
#             directly against the Computers tab page; there is no longer a
#             'Connectivity Check' sub-tab label since it's the only content.
#             Build-ConnectivityTab is now called with -Context $Context (it
#             gained that parameter) so its grid's Delete Computer(s) menu
#             item can address its admin tracking mail correctly.
#endregion

#region -- Register-ComputersTab ----------------------------------------------
function Register-ComputersTab {
    param(
        [System.Windows.Forms.TabPage]$Tab,
        [PSCustomObject]$Context
    )
    $script:CompCtx = $Context
    $script:CompTab = $Tab

    $TW = $Context.TabW
    $TH = $Context.TabH
    $script:_TW = $TW
    $script:_TH = $TH

    Build-ConnectivityTab -Tab $Tab -Context $Context
}
#endregion

Export-ModuleMember -Function Register-ComputersTab
