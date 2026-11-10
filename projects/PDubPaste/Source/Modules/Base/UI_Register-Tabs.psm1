# UI_Register-Tabs.psm1   (BASE TIER)
#
# Builds the main-form tabs. Called once by _AppLauncher.ps1 with the empty
# TabControl and the App context. One function per tab module keeps the Function
# Map (function -> module) meaningful:
#   Overview -> New-OverviewTab  (Base/UI_Tab_Overview.psm1)  -- status + pause
#   Password Config -> New-PasswordsTab (Lite/UI_Tab_Passwords.psm1) -- the 5 slots
#   Environment -> New-EnvironmentTab (Base/UI_Tab_Environment.psm1) -- ADMIN / DEVELOPER only
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

    # PDubPaste: one copy per Windows session - a second launch hands over
    # to the running one (which shows itself and asks for sign-in) and exits.
    try {
        Import-PwNative
        $instance = Get-PwInstanceName
        if (-not [PwPaste.SingleInstance]::TryClaim($instance)) {
            if ([PwPaste.SingleInstance]::SignalExisting($instance)) {
                $App.Log('INFO', 'PwPaste', 'Already running in this session - asked that copy to show itself; this launch exits.')
                Start-Sleep -Milliseconds 1000      # stay foreground while the running copy takes over
            }
            else {
                $App.Log('WARN', 'PwPaste', 'Another copy holds the instance lock but did not answer.')
                [void][System.Windows.Forms.MessageBox]::Show(
                    "PDubPaste is already running but did not respond.`r`n`r`nEnd 'PDubPaste' in Task Manager, then start it again.",
                    'PDubPaste', 'OK', 'Warning')
            }
            [Environment]::Exit(0)
        }
    }
    catch { $App.Log('ERROR', 'PwPaste', "native helpers failed to load: $($_.Exception.Message)") }

    # Start the hotkey engine (hotkeys register only after the first unlock) and
    # shape the window before the tabs are built (the tabs read its state).
    try { Initialize-PwPaste -App $App }
    catch { $App.Log('ERROR', 'PwPaste', "hotkey engine failed to start: $($_.Exception.Message)") }
    try { Initialize-PwWindow -App $App -Form $global:AppForm -Tabs $Tabs }
    catch {
        # fail closed: without the lock screen the settings stay hidden
        $App.Log('ERROR', 'PwPaste', "window setup failed: $($_.Exception.Message)")
        $Tabs.Visible = $false
        $App.SetStatus('Startup failed - see Session.log. Settings are hidden.', 'err')
    }

    $defs = @(
        @{ Title = 'Overview';        Fn = 'New-OverviewTab' }
        @{ Title = 'Password Config'; Fn = 'New-PasswordsTab' }
    )
    # Environment tab: admin password and developer build only. Its function is in
    # Base (both bundles), so this is decided by the tier, not by whether it exists.
    if ([string]$App.Tier -ne 'User') {
        $defs += @{ Title = 'Environment'; Fn = 'New-EnvironmentTab' }
    }
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
