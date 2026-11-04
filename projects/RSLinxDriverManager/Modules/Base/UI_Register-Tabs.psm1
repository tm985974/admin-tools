# UI_Register-Tabs.psm1   (BASE TIER)
#
# Builds the main-form tabs. Called once by _AppLauncher.ps1 with the empty
# TabControl and the App context. One function per tab module keeps the Function
# Map (function -> module) meaningful:
#   Overview    -> New-OverviewTab    (Base/UI_Tab_Overview.psm1)   -- how to use the tool
#   Drivers     -> New-DriversTab     (Lite/UI_Tab_Drivers.psm1)    -- device data -> preview -> drivers on this PC, backups
#   VLAN Lookup -> New-VlanLookupTab  (Lite/UI_Tab_VlanLookup.psm1) -- the table that names the drivers
#   RSLinx      -> New-RSLinxTab      (Lite/UI_Tab_RSLinx.psm1)     -- embedded RSLinx Classic control panel + PC facts
#   Environment -> New-EnvironmentTab (Base/UI_Tab_Environment.psm1) -- environment picker + fields + registered sections
#
# Admin-tier tabs: drop a module in Modules\Admin, define its function, and add
# it to $adminDefs below. It is built only when its function is present (admin
# password or developer build); a user-tier launch never decrypts that module.

function Register-AppTabs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.TabControl]$Tabs,
        [Parameter(Mandatory)] $App
    )

    # Apply the saved app-wide logging settings (Settings\Logging.json) first.
    if (Get-Command Initialize-AppLogging -ErrorAction SilentlyContinue) { Initialize-AppLogging -App $App }

    $defs = @(
        @{ Title = 'Overview'; Fn = 'New-OverviewTab' }
        @{ Title = 'Drivers';     Fn = 'New-DriversTab' }
        @{ Title = 'VLAN Lookup'; Fn = 'New-VlanLookupTab' }
        @{ Title = 'RSLinx';      Fn = 'New-RSLinxTab' }
        @{ Title = 'Environment'; Fn = 'New-EnvironmentTab' }
    )
    $adminDefs = @(
        # @{ Title = 'Admin'; Fn = 'New-AdminTab' }   # example: add admin-tier tabs here
    )

    foreach ($d in ($defs + $adminDefs)) {
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
