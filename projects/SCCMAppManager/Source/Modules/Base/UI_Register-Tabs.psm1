# UI_Register-Tabs.psm1   (BASE TIER - project-owned)
#
# Builds the main-form tabs of SCCM App Manager. Called once by _AppLauncher.ps1.
#   Overview        -> New-OverviewTab        (Base/UI_Tab_Overview.psm1)
#   Update Pipeline -> New-SamPipelineTab     (Lite/UI_Tab_Pipeline.psm1)
#   Software        -> New-SamSoftwareTab     (Lite/UI_Tab_Software.psm1)
#   Collections     -> New-SamCollectionsTab  (Lite/UI_Tab_Collections.psm1)
#   Devices         -> New-SamDevicesTab      (Lite/UI_Tab_Devices.psm1)
#   Environment     -> New-EnvironmentTab     (Base/UI_Tab_Environment.psm1) + SCCM Site page
#
# Admin tier (Modules\Admin\SAM_AdminActions.psm1) adds no tabs: it adds
# right-click entries and buttons (delete, retire, remove members, new
# collection ...) that appear only when its functions are loaded.

function Register-AppTabs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.TabControl]$Tabs,
        [Parameter(Mandatory)] $App
    )

    if (Get-Command Initialize-AppLogging -ErrorAction SilentlyContinue) { Initialize-AppLogging -App $App }

    # Shared state + per-site settings, and the SCCM Site page on the Environment tab
    try {
        Initialize-SamState -App $App
        Register-SamEnvironmentPage
    }
    catch { $App.Log('ERROR', 'Tabs', "SCCM App Manager init failed: $($_.Exception.ToString())") }

    $defs = @(
        @{ Title = 'Overview';        Fn = 'New-OverviewTab' }
        @{ Title = 'Update Pipeline'; Fn = 'New-SamPipelineTab' }
        @{ Title = 'Software';        Fn = 'New-SamSoftwareTab' }
        @{ Title = 'Collections';     Fn = 'New-SamCollectionsTab' }
        @{ Title = 'Devices';         Fn = 'New-SamDevicesTab' }
        @{ Title = 'Environment';     Fn = 'New-EnvironmentTab' }
    )
    $adminDefs = @()

    foreach ($d in ($defs + $adminDefs)) {
        if (-not (Get-Command $d.Fn -ErrorAction SilentlyContinue)) { continue }
        $page = New-Object System.Windows.Forms.TabPage $d.Title
        if (Get-Command Initialize-TabPage -ErrorAction SilentlyContinue) { Initialize-TabPage -App $App -Page $page }
        try { & $d.Fn -Page $page -App $App }
        catch { if ($App) { $App.Log('ERROR', 'Tabs', "$($d.Fn) threw: $($_.Exception.Message)") } }
        $Tabs.TabPages.Add($page)
    }

    Enable-LazyTabActivation -Tabs $Tabs -App $App

    # Loads / reloads SCCM data whenever a SCCM tab is shown (after its lazy build)
    if (Get-Command Register-SamTabWatcher -ErrorAction SilentlyContinue) {
        Register-SamTabWatcher -Tabs $Tabs
        # Open on the Update Pipeline tab once the window is idle
        $open = { if ($Tabs.TabPages.Count -gt 1) { $Tabs.SelectedIndex = 1 } }.GetNewClosure()
        try { [void]$Tabs.BeginInvoke([System.Windows.Forms.MethodInvoker]$open) } catch { }
    }
}
