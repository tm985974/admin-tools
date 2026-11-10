#region -- ADIgnition.Register-DiscoveryTab.psm1 --------------------------------
# Concern : Register-IgnitionTab - builds the Ignition tab content directly
#           (toolbar + gateway grid) by calling Build-IgnitionDiscoveryTab
#           against the main Ignition tab page. Sets $script:IgnCtx,
#           $script:_TW, $script:_TH. Mirrors ADComputers.Register-ComputersTab:
#           the Ignition tab is a single full-page view, not a nested
#           sub-TabControl, so it uses the full TabW/TabH (no tab-strip
#           deduction).
# Load order: after ADIgnition.Discovery.Tab (Build-IgnitionDiscoveryTab);
#           called by UI_Ignition's New-IgnitionTab.
#endregion

#region -- Register-IgnitionTab -------------------------------------------------
function Register-IgnitionTab {
    param(
        [System.Windows.Forms.TabPage]$Tab,
        [PSCustomObject]$Context
    )
    $script:IgnCtx = $Context
    $script:IgnTab = $Tab
    $script:_TW    = $Context.TabW
    $script:_TH    = $Context.TabH
    Build-IgnitionDiscoveryTab -Tab $Tab -Context $Context
}
#endregion

Export-ModuleMember -Function Register-IgnitionTab
