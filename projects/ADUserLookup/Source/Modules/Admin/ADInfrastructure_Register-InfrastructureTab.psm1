#region -- ADInfrastructure.Register-InfrastructureTab.psm1 ------------------
# Concern : Register-InfrastructureTab - builds the Infrastructure tab sub-tab
#           container and calls Build-* for each of the five sub-tabs.
#           Sets $script:InfraCtx, $script:_TW, $script:_TH.
# Load order: 113 - depends on ADInfrastructure.RichText.Header (script scope),
#                             ADInfrastructure.DCHealth.Tab (Build-DCHealthTab),
#                             ADInfrastructure.Trusts.Tab (Build-TrustTab),
#                             ADInfrastructure.ForestInfo.Display (Build-LevelTab),
#                             ADInfrastructure.PrivAudit.Tab (Build-PrivAuditTab),
#                             ADInfrastructure.GPO.Tab (Build-GPOScopeTab)
# Split from: ADInfrastructure.Tab.psm1
# Changes   : Added Privileged Accounts as 7th sub-tab (last in order).
#             Relocated from the removed Groups tab; see
#             ADInfrastructure.PrivAudit.Query.psm1 / .Tab.psm1.
#             Reordered sub-tabs: Forest/Domain Level and Privileged Accounts
#             moved up to sit right after Trusts (was: DC Health, Trusts,
#             DNS, DHCP, GPO, Forest/Domain, Privileged; now: DC Health,
#             Trusts, Forest/Domain, Privileged, DNS, DHCP, GPO).
#             DC Health deferred: removed explicit startup call. The DC Health
#             sub-tab Add_Enter fires too early (TabPages[0] is activated at
#             TabPages.Add() time, before the handler is wired). Instead the
#             Infrastructure PARENT tab's Add_Enter is wired here with a
#             $script:InfraDCBootstrapped guard. On the first click of the
#             Infrastructure parent tab, if DCHealthLoaded is still false the
#             refresh is triggered. The DC sub-tab's own Add_Enter (in
#             Build-DCHealthTab) remains untouched and handles all sub-tab
#             switching after the initial load.
#             REMOVED DNS Lookup and DHCP Leases (moved to the Tools tab,
#             ADTools.Register-ToolsTab) - they're diagnostic/lookup
#             utilities for separate Windows Server roles (DNS, DHCP), not
#             reports on the AD domain/forest's own structure or health the
#             way DC Health/Trusts/Forest Level/Privileged Accounts/GPO
#             Scope are - a better fit for Tools' existing character
#             (Password Generator, Operation Log: on-demand utilities) than
#             Infrastructure's (domain-state reports). This module no
#             longer depends on ADInfrastructure.DNS.Tab /
#             ADInfrastructure.DHCP.Tab at all - both modules are still
#             loaded (their Build-*Tab functions are now called from
#             ADTools.Register-ToolsTab instead), just no longer referenced
#             here.
#             REORDERED sub-tabs to Forest/Domain Level, Trusts, DC Health,
#             Privileged Accounts, GPO Scope (was: DC Health, Trusts,
#             Forest/Domain Level, Privileged Accounts, GPO Scope). Pure
#             display-order change - the DC Health deferred-load bootstrap
#             logic keys off the Infrastructure PARENT tab's own index in
#             the main TabControl, not this sub-tab's position, so it is
#             unaffected by DC Health no longer being sub-tab index 0.
#endregion

#region -- Register-InfrastructureTab -----------------------------------------
function Register-InfrastructureTab {
    param(
        [System.Windows.Forms.TabPage]$Tab,
        [PSCustomObject]$Context
    )
    $script:InfraCtx = $Context
    $script:InfraTab = $Tab

    $PAD    = 8
    $F_UI_B = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $TW     = $Context.TabW
    $TH     = $Context.TabH

    # BUG FIX: $script:_TH used to be set to the raw $TH (the outer Tab's
    # full client height) - but every Build-*Tab function below lays out
    # controls INSIDE one of $subTab's CHILD TabPages, not inside $subTab
    # itself, and a WinForms TabControl's own tab strip consumes real
    # vertical space (~25px) that its child TabPages' client area does not
    # include. Any control positioned near the bottom of a sub-tab page
    # (e.g. a button hugging the assumed bottom edge) would be laid out
    # ~25px lower than the page's actual visible area - the same bug
    # confirmed and fixed in ADBulkOps.Register-BulkOpsTab, applied here
    # since this registrar has the identical nested-TabControl structure.
    $TAB_STRIP_H = 25
    $script:_TW  = $TW
    $script:_TH  = ($TH - ($PAD * 2)) - $TAB_STRIP_H

    $subTab          = New-Object System.Windows.Forms.TabControl
    $subTab.Location = New-Object System.Drawing.Point($PAD, $PAD)
    $subTab.Size     = New-Object System.Drawing.Size(($TW-($PAD*2)), ($TH-($PAD*2)))
    $subTab.Font     = $F_UI_B
    $Tab.Controls.Add($subTab)

    $pages = @(
        @{ Key='level'; Text='  Forest / Domain Level  ' }
        @{ Key='trust'; Text='  Trusts  ' }
        @{ Key='dc';    Text='  DC Health  ' }
        @{ Key='priv';  Text='  Privileged Accounts  ' }
        @{ Key='gpo';   Text='  GPO Scope  ' }
    )
    foreach ($p in $pages) {
        $tp           = New-Object System.Windows.Forms.TabPage
        $tp.Text      = $p.Text
        $tp.BackColor = [System.Drawing.Color]::FromArgb(235,238,242)
        $subTab.TabPages.Add($tp)
        $script:InfraPages[$p.Key] = $tp
    }

    Build-LevelTab     -Tab $script:InfraPages['level']
    Build-TrustTab     -Tab $script:InfraPages['trust']
    Build-DCHealthTab  -Tab $script:InfraPages['dc']
    Build-PrivAuditTab -Tab $script:InfraPages['priv']
    Build-GPOScopeTab  -Tab $script:InfraPages['gpo']

    # DC Health deferred to first click of the Infrastructure parent tab.
    # TabPage.Add_Enter is unreliable for top-level tab header clicks in
    # PS5.1/WinForms - Enter fires on child focus movement, not on tab strip
    # selection. The parent TabControl's SelectedIndexChanged is guaranteed to
    # fire on every tab header click. Capture Tab.Parent and the tab's index
    # into locals before GetNewClosure() so the handler can compare the current
    # selected index without re-querying the live object.
    # $script:DCHealthLoaded is set to $true here (before calling Refresh) to
    # prevent the DC sub-tab's own Add_Enter from triggering a duplicate run
    # if it fires simultaneously when the Infrastructure tab becomes active.
    $script:InfraDCBootstrapped = $false
    $localInfraTab   = $Tab
    $localParentCtrl = $Tab.Parent
    if ($localParentCtrl -is [System.Windows.Forms.TabControl]) {
        $localInfraIdx = $localParentCtrl.TabPages.IndexOf($localInfraTab)
        $localParentCtrl.Add_SelectedIndexChanged(({
            if ($localParentCtrl.SelectedIndex -eq $localInfraIdx -and -not $script:InfraDCBootstrapped) {
                $script:InfraDCBootstrapped = $true
                if (-not $script:DCHealthLoaded) {
                    $script:DCHealthLoaded = $true
                    if (Get-Command Invoke-DCHealthRefresh -ErrorAction SilentlyContinue) {
                        Invoke-DCHealthRefresh
                    }
                }
            }
        }).GetNewClosure())
    }
}
#endregion

Export-ModuleMember -Function Register-InfrastructureTab
