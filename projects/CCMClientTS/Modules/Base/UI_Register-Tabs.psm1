# UI_Register-Tabs.psm1   (BASE TIER, project-owned)
#
# Builds the main-form tabs, in this order:
#   Overview     -> New-OverviewTab      (Base/UI_Tab_Overview.psm1)   what the tool does + the full step sequence
#   Discovery    -> New-CcmDiscoveryTab  (Lite/UI_Tab_Discovery.psm1)  read-only state scan + verdict
#   Repair Steps -> New-CcmRepairTab     (Admin/UI_Tab_Repair.psm1)    run the steps (admin password / developer build only)
#   Logs         -> New-CcmLogsTab       (Lite/UI_Tab_Logs.psm1)       CMTrace-style log viewer
#   Environment  -> New-EnvironmentTab   (Base/UI_Tab_Environment.psm1) site code, MP, client source, repair source
#
# A tab is built only if its function is loaded, so Repair Steps simply does
# not appear in a user-tier session (its module stays sealed under the admin key).

function Register-AppTabs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.TabControl]$Tabs,
        [Parameter(Mandatory)] $App
    )

    # Apply the saved app-wide logging settings (Settings\Logging.json) first.
    if (Get-Command Initialize-AppLogging -ErrorAction SilentlyContinue) { Initialize-AppLogging -App $App }

    $defs = @(
        @{ Title = 'Overview';     Fn = 'New-OverviewTab' }
        @{ Title = 'Discovery';    Fn = 'New-CcmDiscoveryTab' }
        @{ Title = 'Repair Steps'; Fn = 'New-CcmRepairTab' }       # admin tier - skipped when not loaded
        @{ Title = 'Logs';         Fn = 'New-CcmLogsTab' }
        @{ Title = 'Environment';  Fn = 'New-EnvironmentTab' }
    )
    $adminDefs = @()

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
