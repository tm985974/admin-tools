# UI_Register-Tabs.psm1   (BASE TIER)
#
# Builds the main-form tabs. Called once by _AppLauncher.ps1 with the empty
# TabControl and the App context. One function per tab module keeps the Function
# Map (function -> module) meaningful:
#   Overview     -> New-OverviewTab      (Base/UI_Tab_Overview.psm1)     -- how to use File Manager
#   File Manager -> New-FmMainTab        (Lite/UI_Tab_FileManager.psm1)  -- the one page: drive, Scan, list, Move
#                   (More: Drives, History, Check a folder, Consolidate - the old tabs, shown in a window)
#   Environment -> New-EnvironmentTab    (Base/UI_Tab_Environment.psm1)   -- environment picker + fields + registered sections
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

    # The File Manager page on the Environment tab (settings that rarely change).
    if (Get-Command Register-FmEnvironmentPage -ErrorAction SilentlyContinue) {
        try { Register-FmEnvironmentPage } catch { $App.Log('ERROR', 'Tabs', "Register-FmEnvironmentPage threw: $($_.Exception.Message)") }
    }

    # Apply the saved app-wide logging settings (Settings\Logging.json) first.
    if (Get-Command Initialize-AppLogging -ErrorAction SilentlyContinue) { Initialize-AppLogging -App $App }

    $defs = @(
        @{ Title = 'Overview';     Fn = 'New-OverviewTab' }
        @{ Title = 'File Manager'; Fn = 'New-FmMainTab' }
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

    # Lazy activation: a tab can set  $Page.Tag = @{ OnActivate = { ... } }  (or use
    # Set-LazyTabBuild) and that block runs ONCE, the first time the tab is
    # selected - the window opens fast and slow work happens on first view. The
    # first activation is then replayed so handlers wired during the build still
    # see it (see Base\UI_LazyTab.psm1). Switching tabs also clears the status
    # message ($App.SetStatus).
    Enable-LazyTabActivation -Tabs $Tabs -App $App
}
