# UI_Register-Tabs.psm1   (BASE TIER, project-owned)
#
# Builds the main-form tabs. Called once by _AppLauncher.ps1 with the empty
# TabControl and the App context.
#   Overview    -> New-OverviewTab     (Base/UI_Tab_Overview.psm1)   -- what the tool does
#   Library     -> New-LibraryTab      (Lite/UI_Tab_Library.psm1)    -- search, read, run
#   Import      -> New-ImportTab       (Admin/UI_Tab_Import.psm1)    -- admin: pull functions from projects
#   Environment -> New-EnvironmentTab  (Base/UI_Tab_Environment.psm1) -- environments (Domain, Server ...)
#
# A tab is built only if its function is present, so the admin-tier Import tab
# simply does not appear in a user-tier session.

function Register-AppTabs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.TabControl]$Tabs,
        [Parameter(Mandatory)] $App
    )

    # Apply the saved app-wide logging settings (Settings\Logging.json) first.
    if (Get-Command Initialize-AppLogging -ErrorAction SilentlyContinue) { Initialize-AppLogging -App $App }

    $defs = @(
        @{ Title = 'Overview';    Fn = 'New-OverviewTab' }
        @{ Title = 'Library';     Fn = 'New-LibraryTab' }
        @{ Title = 'Import';      Fn = 'New-ImportTab' }        # admin tier
        @{ Title = 'Environment'; Fn = 'New-EnvironmentTab' }
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

    # open on the Library (after the lazy hook is wired, so it builds on first view)
    foreach ($p in $Tabs.TabPages) { if ($p.Text -eq 'Library') { $Tabs.SelectedTab = $p; break } }
}
