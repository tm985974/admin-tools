# UI_Register-Tabs.psm1   (BASE TIER)   -- AD Admin
#
# Tab order and tiering (titles and order match AD Admin 1.6.1):
#   Everyone (user + admin):  Overview, User Lookup, Environment
#   Admin only:               Users, Groups, Account Management, Computers,
#                             Bulk Operations, Infrastructure, Tools, Audit
#
# User-tier launches never decrypt Modules\Admin, so those functions are
# undefined and their tabs are skipped. The admin password (full tier) and the
# developer build load them, so they appear. Environment is one page for
# everyone; an admin session also shows the AD environment settings below the
# fields (registered by AD_Core with Register-EnvironmentSection).

function Register-AppTabs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.TabControl]$Tabs,
        [Parameter(Mandatory)] $App
    )

    # Apply the saved app-wide logging settings (Settings\Logging.json) first.
    if (Get-Command Initialize-AppLogging -ErrorAction SilentlyContinue) { Initialize-AppLogging -App $App }

    $everyoneLead = @(
        @{ Title = 'Overview';    Fn = 'New-OverviewTab' }
        @{ Title = 'User Lookup'; Fn = 'New-UserLookupTab' }
    )
    # Admin-tier tabs, in the original tool's order. Titles match the source.
    $adminDefs = @(
        @{ Title = 'Users';              Fn = 'New-DirectoryTab' }
        @{ Title = 'Groups';             Fn = 'New-GroupsTab' }
        @{ Title = 'Account Management'; Fn = 'New-UserActionsTab' }
        @{ Title = 'Computers';          Fn = 'New-ComputersTab' }
        @{ Title = 'Ignition';           Fn = 'New-IgnitionTab' }
        @{ Title = 'Bulk Operations';    Fn = 'New-BulkOpsTab' }
        @{ Title = 'Infrastructure';     Fn = 'New-InfrastructureTab' }
        @{ Title = 'Tools';              Fn = 'New-ToolsTab' }
        @{ Title = 'Audit';              Fn = 'New-AuditTab' }
    )
    $everyoneTail = @(
        @{ Title = 'Environment'; Fn = 'New-EnvironmentTab' }
    )

    foreach ($d in ($everyoneLead + $adminDefs + $everyoneTail)) {
        if (-not (Get-Command $d.Fn -ErrorAction SilentlyContinue)) { continue }
        $page = New-Object System.Windows.Forms.TabPage $d.Title
        if (Get-Command Initialize-TabPage -ErrorAction SilentlyContinue) { Initialize-TabPage -App $App -Page $page }
        try { & $d.Fn -Page $page -App $App }
        catch { if ($App) { $App.Log('ERROR','Tabs',"$($d.Fn) threw: $($_.Exception.Message)") } }
        $Tabs.TabPages.Add($page)
    }

    # Lazy activation: a tab can set  $Page.Tag = @{ OnActivate = { ... } }  (or use
    # Set-LazyTabBuild) and that block runs ONCE, the first time the tab is
    # selected - the window opens fast and slow work happens on first view. The
    # first activation is then replayed so handlers wired during the build still
    # see it (see Base\UI_LazyTab.psm1). Switching tabs also clears the status
    # message ($App.SetStatus).
    Enable-LazyTabActivation -Tabs $Tabs -App $App
}
