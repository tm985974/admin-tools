# UI_PwWindow.psm1   (LITE TIER)
#
# Shapes the template's main window for this small tool:
#   * compact window instead of the full-screen layout
#   * a lock screen over the tabs until you pass the Windows sign-in check
#     (Services_PwUnlock.psm1). It asks when the app starts, when the window is
#     brought back from the tray / taskbar, and when another launch hands over to
#     this one. The window locks again when minimized, hidden to the tray, or
#     idle for the configured minutes. Hotkeys keep working while the WINDOW is
#     locked; they only start after the first unlock.
#   * tray icon (Open / Pause / Exit) and optional minimize-to-tray
#   * clean shutdown (the C# side also releases hotkeys and ends the process)

function Initialize-PwWindow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $App,
        [Parameter(Mandatory)] [System.Windows.Forms.Form]$Form,
        [Parameter(Mandatory)] [System.Windows.Forms.TabControl]$Tabs
    )
    $T = $App.Theme

    # compact window (the template opens at full target-screen size)
    $Form.MinimumSize   = New-Object System.Drawing.Size(1000, 520)
    $Form.WindowState   = 'Normal'
    $Form.StartPosition = 'CenterScreen'
    $Form.Size          = New-Object System.Drawing.Size(1180, 600)

    # ---- lock screen ----
    $ov = New-Object System.Windows.Forms.Panel
    $ov.Dock = 'Fill'; $ov.BackColor = $T.Surface

    $box = New-Object System.Windows.Forms.Panel
    $box.Size = New-Object System.Drawing.Size(520, 190)
    $lockTitle = New-Object System.Windows.Forms.Label
    $lockTitle.Text = 'PDubPaste is locked'
    $lockTitle.AutoSize = $true; $lockTitle.Location = New-Object System.Drawing.Point(0, 0)
    $lockTitle.ForeColor = $T.Title
    $lockTitle.Font = New-Object System.Drawing.Font($T.FontName, ($T.FontSizePt + 6), [System.Drawing.FontStyle]::Bold)
    $lockSub = New-Object System.Windows.Forms.Label
    $lockSub.AutoSize = $false; $lockSub.Size = New-Object System.Drawing.Size(520, 48)
    $lockSub.Location = New-Object System.Drawing.Point(2, 50); $lockSub.ForeColor = $T.Muted
    $btnUnlock = $T.MakeButton('Unlock')
    $btnUnlock.AutoSize = $false; $btnUnlock.Size = New-Object System.Drawing.Size(130, 34)
    $btnUnlock.Location = New-Object System.Drawing.Point(2, 110)
    $btnExit = $T.MakeButton('Exit')
    $btnExit.AutoSize = $false; $btnExit.Size = New-Object System.Drawing.Size(100, 34)
    $btnExit.Location = New-Object System.Drawing.Point(144, 110)
    $box.Controls.AddRange(@($lockTitle, $lockSub, $btnUnlock, $btnExit))
    $ov.Controls.Add($box)
    $ov.Add_Resize({
        $x = [Math]::Max(10, [int](($ov.ClientSize.Width  - $box.Width)  / 2))
        $y = [Math]::Max(10, [int](($ov.ClientSize.Height - $box.Height) / 2.5))
        $box.Location = [System.Drawing.Point]::new($x, $y)
    }.GetNewClosure())

    $Form.Controls.Add($ov)
    $ov.BringToFront()

    # show/hide the lock screen from the state
    $applyLock = {
        $st = Get-PwState
        if ($st.WindowLocked) {
            $Tabs.Visible = $false
            $ov.Visible = $true; $ov.BringToFront()
            $lockSub.Text = $(if (-not $st.Unlocked) { "Sign in with your Windows account (Windows Hello or your Windows password) to start the hotkeys." }
                              else { "Your hotkeys are still active. Sign in with your Windows account to see or change the settings." })
        }
        else {
            $ov.Visible = $false
            $Tabs.Visible = $true
        }
    }.GetNewClosure()

    $lock = {
        $st = Get-PwState
        if ($st.WindowLocked) { return }
        $st.WindowLocked = $true
        Set-PwSuspended -App $App -Suspended $false
        & $applyLock
        $App.Diag('PwUnlock', 'Window locked.')
    }.GetNewClosure()

    $unlock = {
        $st = Get-PwState
        if (-not $st.WindowLocked -or $st.Unlocking) { return }
        [void](Invoke-PwUnlock -App $App -Owner $Form)
        & $applyLock
    }.GetNewClosure()

    # run the unlock after the current event has finished (never inside Resize etc.)
    $unlockLater = { try { [void]$Form.BeginInvoke([System.Action]$unlock) } catch { } }.GetNewClosure()

    $btnUnlock.Add_Click({ & $unlock }.GetNewClosure())
    $btnExit.Add_Click({ $Form.Close() }.GetNewClosure())

    # ---- tray ----
    $tray = New-Object System.Windows.Forms.NotifyIcon
    $tray.Text = 'PDubPaste'
    try { $tray.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon([System.Windows.Forms.Application]::ExecutablePath) }
    catch { $tray.Icon = [System.Drawing.SystemIcons]::Shield }
    if (-not $tray.Icon) { $tray.Icon = [System.Drawing.SystemIcons]::Shield }

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $miOpen  = $menu.Items.Add('Open')
    $miPause = $menu.Items.Add('Pause hotkeys')
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $miExit  = $menu.Items.Add('Exit')
    $miOpen.Font = New-Object System.Drawing.Font($miOpen.Font, [System.Drawing.FontStyle]::Bold)
    $tray.ContextMenuStrip = $menu
    $tray.Visible = $true

    $flags = @{ TipShown = $false; WasMinimized = $false; InactiveSince = $null }

    $restore = {
        $Form.Show()
        if ($Form.WindowState -eq 'Minimized') { $Form.WindowState = 'Normal' }
        $Form.Activate()
        $front = [PwPaste.Lifetime]::BringToFront($Form.Handle)
        $App.Diag('PwPaste', "Window restored (in front: $front).")
        & $unlockLater
    }.GetNewClosure()

    $tray.Add_MouseDoubleClick({ & $restore }.GetNewClosure())
    $miOpen.Add_Click({ & $restore }.GetNewClosure())
    $miExit.Add_Click({ $Form.Close() }.GetNewClosure())
    $miPause.Add_Click({
        $st = Get-PwState
        if (-not $st.Paused) { Set-PwPaused -App $App -Paused $true; return }
        # resuming turns passwords back on - only for a verified user
        if ($st.WindowLocked) {
            $tray.ShowBalloonTip(2500, 'PDubPaste', 'Unlock the window, then resume the hotkeys on the Overview tab.', 'Info')
            & $restore
            return
        }
        Set-PwPaused -App $App -Paused $false
    }.GetNewClosure())

    Register-PwStateChangedHandler -Handler ({
        $st = Get-PwState
        $miPause.Text = $(if ($st.Paused) { 'Resume hotkeys' } else { 'Pause hotkeys' })
        $tray.Text = $(if (-not $st.Unlocked) { 'PDubPaste (locked)' } elseif ($st.Paused) { 'PDubPaste (paused)' } else { 'PDubPaste' })
    }.GetNewClosure())

    # ---- lock on minimize / hide; ask again on restore ----
    $Form.Add_Resize({
        $st = Get-PwState
        if ($Form.WindowState -eq 'Minimized') {
            $flags.WasMinimized = $true
            & $lock
            if ($st.Options.MinimizeToTray) {
                $Form.Hide()
                if (-not $flags.TipShown) {
                    $flags.TipShown = $true
                    $tray.ShowBalloonTip(2500, 'PDubPaste', 'Still running in the tray - hotkeys stay active.', 'Info')
                }
            }
        }
        elseif ($flags.WasMinimized) {
            $flags.WasMinimized = $false
            if ($Form.Visible) { & $unlockLater }
        }
    }.GetNewClosure())

    # ---- idle lock ----
    $Form.Add_Activated({ $flags.InactiveSince = $null }.GetNewClosure())
    $Form.Add_Deactivate({ $flags.InactiveSince = Get-Date }.GetNewClosure())
    $idle = New-Object System.Windows.Forms.Timer
    $idle.Interval = 15000
    $idle.Add_Tick({
        $st = Get-PwState
        $mins = [int]$st.Options.LockAfterMinutes
        if ($mins -le 0 -or $st.WindowLocked -or $st.Unlocking) { return }
        $limit = $mins * 60
        $away = if ($flags.InactiveSince) { ((Get-Date) - $flags.InactiveSince).TotalSeconds } else { 0 }
        if ([PwPaste.Lifetime]::IdleSeconds() -ge $limit -or $away -ge $limit) { & $lock }
    }.GetNewClosure())
    $idle.Start()

    # ---- a second launch asks this copy to show itself ----
    # (built here at function level: a closure created INSIDE another closure
    # does not capture that closure's variables - $restore would be empty)
    $onShowRequest = {
        $App.Log('INFO', 'PwPaste', 'Another launch asked this copy to show itself.')
        if ((Get-PwState).Unlocking) {
            # a sign-in prompt is already open (maybe behind other windows) - bring it forward
            foreach ($f in [System.Windows.Forms.Application]::OpenForms) { if ($f.Modal) { [void][PwPaste.Lifetime]::BringToFront($f.Handle) } }
            return
        }
        & $restore
    }.GetNewClosure()
    $showRequestHandler = [System.EventHandler]$onShowRequest

    # ---- first show: ask right away; start listening for a second launch ----
    $Form.Add_Shown({
        # The tray menu belongs to no control, so the tooltip sweep never finds it:
        # hand it over once the catalog is loaded (Config\ToolTips.json "Tray > ...").
        try {
            if (Get-Command Register-AppToolTipMenu -ErrorAction SilentlyContinue) {
                [void](Get-AppToolTipCatalog -App $App)
                Register-AppToolTipMenu -Menu $menu -Context @('Tray')
            }
        } catch { $App.Log('WARN', 'ToolTips', "Tray menu tooltips: $($_.Exception.Message)") }
        & $applyLock
        [PwPaste.SingleInstance]::Listen($Form, $showRequestHandler)
        & $unlockLater
    }.GetNewClosure())

    $Form.Add_FormClosed({
        try { $idle.Stop(); $idle.Dispose() } catch { }
        try { Stop-PwPaste -App $App } catch { }
        try { $tray.Visible = $false; $tray.Dispose() } catch { }
    }.GetNewClosure())

    & $applyLock
}
