# UI_Register-Tabs.psm1   (BASE TIER, project-owned)
#
# Builds the main-form tabs. Called once by _AppLauncher.ps1 with the empty
# TabControl and the App context.
#   Overview     -> New-OverviewTab     (Base/UI_Tab_Overview.psm1)    -- the workflow
#   This Machine -> New-ThisMachineTab  (Lite/UI_Tab_ThisMachine.psm1) -- license the PC the app runs on
#   Fleet        -> New-FleetTab        (Lite/UI_Tab_Fleet.psm1)       -- collect / apply over WinRM
#   Environment  -> New-EnvironmentTab  (Base/UI_Tab_Environment.psm1) -- + the Radmin page (Lite/UI_Env_Radmin.psm1)
#
# Admin-tier tabs: drop a module in Modules\Admin, define its function, and add
# it to $adminDefs below. (To make Fleet admin-only, move UI_Tab_Fleet.psm1 and
# Services_RadminBatch.psm1 to Modules\Admin and its entry to $adminDefs.)

function Register-AppTabs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.TabControl]$Tabs,
        [Parameter(Mandatory)] $App
    )

    # Apply the saved app-wide logging settings (Settings\Logging.json) first.
    if (Get-Command Initialize-AppLogging -ErrorAction SilentlyContinue) { Initialize-AppLogging -App $App }

    # The Radmin page on the Environment tab (built when that tab is first viewed).
    if (Get-Command Register-RadminEnvironmentPage -ErrorAction SilentlyContinue) {
        try { Register-RadminEnvironmentPage } catch { $App.Log('ERROR', 'Tabs', "Register-RadminEnvironmentPage threw: $($_.Exception.Message)") }
    }

    $defs = @(
        @{ Title = 'Overview';     Fn = 'New-OverviewTab' }
        @{ Title = 'This Machine'; Fn = 'New-ThisMachineTab' }
        @{ Title = 'Fleet';        Fn = 'New-FleetTab' }
        @{ Title = 'Environment';  Fn = 'New-EnvironmentTab' }
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

    # Lazy activation (see Base\UI_LazyTab.psm1): This Machine and Fleet build on first view.
    Enable-LazyTabActivation -Tabs $Tabs -App $App
}
