#region -- ADTools.Register-ToolsTab.psm1 -------------------------------------
# Concern : Register-ToolsTab - builds the Tools tab sub-tab container and
#           calls Build-PwGenTab, Build-NamingTab, Build-DNSTab, Build-DHCPTab,
#           Build-OpLogTab, Build-EnvTab.
#           Sets $script:ToolsCtx, $script:_TW, $script:_TH.
# Load order: 126 - depends on ADTools.PasswordGenerator.Engine (script scope),
#                            ADTools.PasswordGenerator.Tab (Build-PwGenTab),
#                            ADAudit.Naming.Tab (Build-NamingTab) [93],
#                            ADInfrastructure.DNS.Tab (Build-DNSTab) [106],
#                            ADInfrastructure.DHCP.Tab (Build-DHCPTab) [108],
#                            ADTools.Operations.Tab (Build-OpLogTab),
#                            ADTools.Environment.Tab (Build-EnvTab),
#                            ADTools.AbortReboot.Tab (Build-AbortRebootTab)
# Split from: ADTools.Tab.psm1
# Changes   : Added 'Domain Defaults' sub-tab (last position) - editable
#             per-domain settings (SMTP, IPCS suffixes, home drive, default
#             OUs) backed by Services.DomainDefaults.Config.
#             Removed the 'Bulk Onboarding' sub-tab - moved to the new Bulk
#             Operations tab (ADBulkOps.Register-BulkOpsTab, page "Bulk Add
#             Users") as part of consolidating every bulk action into one
#             place. ADTools.BulkOnboard.Tab (Build-BulkTab) is still loaded
#             and completely unmodified - Register-BulkOpsTab calls it now
#             instead of this function, and additionally sets
#             $script:ToolsCtx itself so that module's pre-existing
#             (unchanged) dependency on that variable keeps resolving
#             correctly under its new tab. This function no longer depends
#             on ADTools.BulkOnboard.Tab at all.
#             ADDED 'DNS Lookup' and 'DHCP Leases' sub-tabs - relocated from
#             Infrastructure (ADInfrastructure.Register-InfrastructureTab):
#             they're on-demand diagnostic/lookup utilities for separate
#             Windows Server roles, not reports on the AD domain/forest's
#             own structure the way Infrastructure's remaining five sub-tabs
#             are - a better fit for Tools' existing character. Build-DNSTab
#             / Build-DHCPTab (and the query modules underneath them,
#             ADInfrastructure.DNS.Lookup / ADInfrastructure.DHCP.Query) are
#             completely unmodified - both still read $script:InfraCtx
#             directly rather than accepting a -Context parameter, exactly
#             the same pre-existing coupling Build-BulkTab has to
#             $script:ToolsCtx (see that change's note above). This function
#             now sets $script:InfraCtx = $Context too, purely so that
#             coupling keeps resolving correctly now that these two are
#             hosted under Tools instead of Infrastructure.
#             ADInfrastructure.Register-InfrastructureTab also still sets
#             $script:InfraCtx to the same effective value for its own
#             remaining sub-tabs - harmless, since both registrars run once
#             at startup against the same $Context object.
#             REMOVED 'Domain Defaults' sub-tab - promoted to its own
#             main-level tab (ADTools.Register-DomainDefaultsTab, a new
#             thin registrar). Build-DomainDefaultsTab itself is
#             unchanged - it already read $script:ToolsCtx/$script:_TW/
#             $script:_TH rather than a -Context parameter, so no edits
#             were needed there; only the caller moved.
#             ADDED 'Naming Convention' sub-tab (was its own main-level
#             tab, ADAudit.Register-NamingTab - now dead code, removed from
#             the launcher's module load order). Build-NamingTab
#             (ADAudit.Naming.Tab) needed one change to be hosted here
#             safely - see that module's own header - its sizing source
#             changed from $Context.TabW/TabH to $script:_TW/$script:_TH,
#             same as every sub-tab on this page.
#             REORDERED sub-tabs to Password Generator, Naming Convention,
#             DNS Lookup, DHCP Leases, Operation Log, Environment Report.
#             ADDED 'Abort Remote Reboot' sub-tab (last position) - paste a
#             list of computer names and abort a pending remote restart on
#             each (Build-AbortRebootTab / ADTools.AbortReboot.Tab, backed
#             by Invoke-AbortRemoteRestart / ADComputers.Restart.Engine).
#             Companion to the Computers grid's new Restart Now / Timed
#             Restart right-click items (ADDirectory.Menus).
#             ADDED 'Ping List' sub-tab (last position, v1.2.12) - paste a list
#             of computer names and ping them all once or continuously
#             (Build-PingListTab / ADTools.PingList.Tab, on the same group-ping
#             panel as the computer menu's "Ping Selected..." dialog).
#             ADDED 'Set DNS' sub-tab (last position, v1.2.15) - paste a list of
#             computer names and set their DNS servers (and dynamic-registration
#             flag) over WinRM (Build-SetDnsTab / ADTools.SetDns.Tab, backed by
#             Invoke-SetRemoteDns / ADTools.SetDns.Engine). Replaces the old
#             standalone RemoteDNSChange.ps1; uses Invoke-Command rather than
#             remote WMI/DCOM. Every OK/FAIL goes to the Activity Log.
#endregion

#region -- Register-ToolsTab --------------------------------------------------
function Register-ToolsTab {
    param(
        [System.Windows.Forms.TabPage]$Tab,
        [PSCustomObject]$Context
    )
    $script:ToolsCtx = $Context
    $script:ToolsTab = $Tab
    # See module header - Build-DNSTab/Build-DHCPTab (and the query modules
    # underneath them) read this directly rather than accepting a -Context
    # parameter.
    $script:InfraCtx = $Context

    $PAD    = 8
    $F_UI_B = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $TW     = $Context.TabW
    $TH     = $Context.TabH

    # BUG FIX: $script:_TH used to be set to the raw $TH (the outer Tab's
    # full client height) - but every Build-*Tab function below (including
    # the relocated Build-DNSTab/Build-DHCPTab) lays out controls INSIDE one
    # of $subTab's CHILD TabPages, not inside $subTab itself, and a
    # WinForms TabControl's own tab strip consumes real vertical space
    # (~25px) that its child TabPages' client area does not include - the
    # same bug confirmed and fixed in ADBulkOps.Register-BulkOpsTab, applied
    # here since this registrar has the identical nested-TabControl
    # structure.
    $TAB_STRIP_H = 25
    $script:_TW  = $TW
    $script:_TH  = ($TH - ($PAD * 2)) - $TAB_STRIP_H

    $subTab          = New-Object System.Windows.Forms.TabControl
    $subTab.Location = New-Object System.Drawing.Point($PAD, $PAD)
    $subTab.Size     = New-Object System.Drawing.Size(($TW-($PAD*2)), ($TH-($PAD*2)))
    $subTab.Font     = $F_UI_B
    $Tab.Controls.Add($subTab)

    $pages = @(
        @{ Key='pwgen'; Text='  Password Generator  ' }
        @{ Key='naming'; Text='  Naming Convention  ' }
        @{ Key='dns';   Text='  DNS Lookup  ' }
        @{ Key='dhcp';  Text='  DHCP Leases  ' }
        @{ Key='oplog'; Text='  Operation Log  ' }
        @{ Key='env';   Text='  Environment Report  ' }
        @{ Key='abortreboot'; Text='  Abort Remote Reboot  ' }
        @{ Key='pinglist';    Text='  Ping List  ' }
        @{ Key='setdns';      Text='  Set DNS  ' }
    )
    foreach ($p in $pages) {
        $tp           = New-Object System.Windows.Forms.TabPage
        $tp.Text      = $p.Text
        $tp.BackColor = [System.Drawing.Color]::FromArgb(235,238,242)
        $subTab.TabPages.Add($tp)
        $script:ToolsPages[$p.Key] = $tp
    }

    Build-PwGenTab -Tab $script:ToolsPages['pwgen']
    Build-NamingTab -Tab $script:ToolsPages['naming'] -Context $Context
    Build-DNSTab   -Tab $script:ToolsPages['dns']
    Build-DHCPTab  -Tab $script:ToolsPages['dhcp']
    Build-OpLogTab -Tab $script:ToolsPages['oplog']
    Build-EnvTab   -Tab $script:ToolsPages['env']
    Build-AbortRebootTab -Tab $script:ToolsPages['abortreboot']
    Build-PingListTab    -Tab $script:ToolsPages['pinglist']
    Build-SetDnsTab      -Tab $script:ToolsPages['setdns']
}
#endregion

Export-ModuleMember -Function Register-ToolsTab
