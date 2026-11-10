# UI_Tab_Passwords.psm1   (LITE TIER)
#
# "Password Config" tab: the 5 slots. Per slot:
#   On | Name | Password (+Show, Forget) | Hotkey | Method | Enter after | Status
#
# Saved passwords are never loaded back into the form. An empty password box
# with "(saved)" hint means "keep the saved one"; typing replaces it; Forget
# removes it. Hotkey boxes capture the combo you press (Backspace/Delete clears),
# and all hotkeys are released while a hotkey box has focus. Nothing changes
# until Save.

function New-PasswordsTab {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.TabPage]$Page,
        [Parameter(Mandatory)] $App
    )
    $st = Get-PwState
    $T  = $App.Theme

    $hdr = New-Object System.Windows.Forms.Label
    $hdr.Text = 'Password Config'; $hdr.Dock = 'Top'; $hdr.Height = 30
    Set-HeaderStyle -App $App -Label $hdr; $hdr.AutoSize = $false

    $sub = New-Object System.Windows.Forms.Label
    $sub.Dock = 'Top'; $sub.Height = 36; $sub.ForeColor = $T.Muted
    $sub.Text = "Click a Hotkey box and press the combo (Ctrl / Alt / Win + a key). Backspace clears it.  " +
                "Leave a password box empty to keep the saved one (Show reveals it).  Changes apply when you click Save."

    # ---- grid ----
    $grid = New-Object System.Windows.Forms.TableLayoutPanel
    $grid.Dock = 'Top'; $grid.AutoSize = $true; $grid.AutoSizeMode = 'GrowAndShrink'
    $grid.ColumnCount = 9; $grid.RowCount = 6
    $grid.Padding = New-Object System.Windows.Forms.Padding(0, 6, 0, 6)
    # columns size to their contents (fixed widths clipped under display scaling)
    for ($c = 0; $c -lt 9; $c++) { [void]$grid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('AutoSize'))) }

    $titles = 'On', 'Name', 'Password', '', '', 'Hotkey', 'Method', 'Enter after', 'Status'
    for ($c = 0; $c -lt $titles.Count; $c++) {
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $titles[$c]; $l.AutoSize = $true; $l.ForeColor = $T.Section
        $l.Font = New-AppFont -App $App -Style ([System.Drawing.FontStyle]::Bold)
        $l.Margin = New-Object System.Windows.Forms.Padding(3, 2, 3, 4)
        $grid.Controls.Add($l, $c, 0)
    }

    # per-row working state: pending hotkey, pending forget
    $rows = @{}
    foreach ($i in 1..5) {
        $r = @{ Index = $i; Mods = 0; Key = 0; Forget = $false; Revealed = $false; Filling = $false }

        $r.On = New-Object System.Windows.Forms.CheckBox
        $r.On.AutoSize = $true; $r.On.Margin = New-Object System.Windows.Forms.Padding(8, 6, 3, 3)

        $r.Name = New-Object System.Windows.Forms.TextBox
        $r.Name.Width = 150; $r.Name.MaxLength = 40

        $r.Pw = New-Object System.Windows.Forms.TextBox
        $r.Pw.Width = 200; $r.Pw.UseSystemPasswordChar = $true; $r.Pw.MaxLength = 512

        $r.Show = New-Object System.Windows.Forms.CheckBox
        $r.Show.Text = 'Show'; $r.Show.AutoSize = $true; $r.Show.Margin = New-Object System.Windows.Forms.Padding(3, 6, 3, 3)

        $r.ForgetBtn = $T.MakeButton('Forget')   # theme size (min 80 x 26)

        $r.Hk = New-Object System.Windows.Forms.TextBox
        $r.Hk.Width = 150; $r.Hk.ReadOnly = $true; $r.Hk.ShortcutsEnabled = $false
        $r.Hk.BackColor = [System.Drawing.SystemColors]::Window; $r.Hk.Cursor = [System.Windows.Forms.Cursors]::Hand

        $r.Method = New-Object System.Windows.Forms.ComboBox
        $r.Method.DropDownStyle = 'DropDownList'; $r.Method.Width = 88
        [void]$r.Method.Items.AddRange(@('Type', 'Clipboard'))

        $r.Enter = New-Object System.Windows.Forms.CheckBox
        $r.Enter.AutoSize = $true; $r.Enter.Margin = New-Object System.Windows.Forms.Padding(24, 6, 3, 3)

        $r.Status = New-Object System.Windows.Forms.Label
        $r.Status.AutoSize = $true; $r.Status.Margin = New-Object System.Windows.Forms.Padding(3, 6, 3, 3)

        # Check boxes without text: the catalog matches on text, so set these here.
        Set-AppToolTip -Control $r.On -Text "Turn this password's hotkey on or off (applies when you click Save)."
        Set-AppToolTip -Control $r.Enter -Text 'Press Enter after the password is sent (e.g. to submit a sign-in box).'

        $col = 0
        foreach ($ctl in @($r.On, $r.Name, $r.Pw, $r.Show, $r.ForgetBtn, $r.Hk, $r.Method, $r.Enter, $r.Status)) {
            $grid.Controls.Add($ctl, $col, $i); $col++
        }
        $rows[$i] = $r
    }

    # ---- options + buttons ----
    $opt = New-Object System.Windows.Forms.FlowLayoutPanel
    $opt.Dock = 'Top'; $opt.AutoSize = $true; $opt.WrapContents = $false
    $opt.Padding = New-Object System.Windows.Forms.Padding(0, 10, 0, 0)

    $chkTray = New-Object System.Windows.Forms.CheckBox
    $chkTray.Text = 'Minimize to the system tray (hotkeys keep working)'; $chkTray.AutoSize = $true
    $chkTray.Margin = New-Object System.Windows.Forms.Padding(3, 6, 24, 3)
    $chkPaused = New-Object System.Windows.Forms.CheckBox
    $chkPaused.Text = 'Start with hotkeys paused'; $chkPaused.AutoSize = $true
    $chkPaused.Margin = New-Object System.Windows.Forms.Padding(3, 6, 3, 3)
    $lblLock = New-Object System.Windows.Forms.Label
    $lblLock.Text = 'Lock the window after'; $lblLock.AutoSize = $true
    $lblLock.Margin = New-Object System.Windows.Forms.Padding(24, 8, 3, 3)
    $numLock = New-Object System.Windows.Forms.NumericUpDown
    $numLock.Minimum = 0; $numLock.Maximum = 240; $numLock.Width = 56
    $numLock.Margin = New-Object System.Windows.Forms.Padding(3, 5, 3, 3)
    $lblLock2 = New-Object System.Windows.Forms.Label
    $lblLock2.Text = 'min idle (0 = only when minimized)'; $lblLock2.AutoSize = $true
    $lblLock2.Margin = New-Object System.Windows.Forms.Padding(3, 8, 3, 3)
    $opt.Controls.Add($chkTray); $opt.Controls.Add($chkPaused)
    $opt.Controls.Add($lblLock); $opt.Controls.Add($numLock); $opt.Controls.Add($lblLock2)

    $btns = New-Object System.Windows.Forms.FlowLayoutPanel
    $btns.Dock = 'Top'; $btns.AutoSize = $true; $btns.WrapContents = $false
    $btns.Padding = New-Object System.Windows.Forms.Padding(0, 12, 0, 0)
    $btnSave = $T.MakeButton('Save');   $btnSave.AutoSize = $false;   $btnSave.Size   = New-Object System.Drawing.Size(110, 30)
    $btnRevert = $T.MakeButton('Revert'); $btnRevert.AutoSize = $false; $btnRevert.Size = New-Object System.Drawing.Size(110, 30)
    $msg = New-Object System.Windows.Forms.Label
    $msg.AutoSize = $true; $msg.Margin = New-Object System.Windows.Forms.Padding(12, 8, 3, 3)
    $btns.Controls.Add($btnSave); $btns.Controls.Add($btnRevert); $btns.Controls.Add($msg)

    $notes = New-Object System.Windows.Forms.Label
    $notes.Dock = 'Top'; $notes.AutoSize = $false; $notes.Height = 96; $notes.ForeColor = $T.Muted
    $notes.Padding = New-Object System.Windows.Forms.Padding(0, 14, 0, 0)
    $notes.Text = "Type = sent as keystrokes, never touches the clipboard (use this by default).  " +
                  "Clipboard = for apps that ignore typed keys (some remote consoles); the clipboard is restored after ~1 second " +
                  "and the entry is kept out of Win+V history.`r`n" +
                  "Passwords are encrypted with your Windows account (DPAPI) and stored only on this PC. " +
                  "The window asks for Windows Hello or your Windows password when it opens, is restored, or after the idle time above."

    # ---- helpers (closures over the controls) ----
    $setHotkeyText = {
        param($r)
        $txt = Format-PwHotkey -Modifiers $r.Mods -Key $r.Key
        $r.Hk.Text = $(if ($txt) { $txt } else { '' })
    }

    $setPwCue = {
        param($r, $hasSaved)
        $cue = if ($r.Forget) { '(will be removed on Save)' } elseif ($hasSaved) { '(saved - type to replace)' } else { '(empty)' }
        $r.Pw.Tag = $cue
        if ($r.Pw.IsHandleCreated) { [PwPaste.Sender]::SetCue($r.Pw.Handle, $cue) }
    }

    $loadForm = {
        $st2 = Get-PwState
        foreach ($s in $st2.Slots) {
            $r = $rows[[int]$s.Index]
            $r.On.Checked = [bool]$s.Enabled
            $r.Name.Text = [string]$s.Name
            $r.Show.Checked = $false                    # hides / clears a revealed password
            $r.Pw.Text = ''; $r.Forget = $false; $r.Revealed = $false
            $r.Mods = [int]$s.Modifiers; $r.Key = [int]$s.Key
            & $setHotkeyText $r
            $r.Method.SelectedItem = [string]$s.Method
            $r.Enter.Checked = [bool]$s.SendEnter
            & $setPwCue $r ([bool]($s.Secret -and $s.Secret.Length -gt 0))
        }
        $chkTray.Checked = [bool]$st2.Options.MinimizeToTray
        $chkPaused.Checked = [bool]$st2.Options.StartPaused
        $numLock.Value = [decimal][Math]::Min(240, [Math]::Max(0, [int]$st2.Options.LockAfterMinutes))
    }.GetNewClosure()

    $refreshStatus = {
        $st2 = Get-PwState
        foreach ($i2 in 1..5) {
            $r = $rows[$i2]
            $s = [string]$st2.Status[$i2]
            $r.Status.Text = $s
            $r.Status.ForeColor = if ($s -eq 'Active') { [System.Drawing.Color]::FromArgb(30, 130, 60) }
                                  elseif ($s -in @('Off', 'Paused', 'Editing', 'No password', 'No hotkey', 'Locked')) { $T.Muted }
                                  else { [System.Drawing.Color]::FromArgb(190, 40, 40) }
        }
    }.GetNewClosure()

    # ---- wire rows ----
    foreach ($i in 1..5) {
        $r = $rows[$i]

        $r.ForgetBtn.Add_Click({
            $r.Forget = $true; $r.Pw.Text = ''; $r.On.Checked = $false
            & $setPwCue $r $false
        }.GetNewClosure())

        # cue text lives in .Tag and is (re)applied whenever the box gets a new
        # handle - toggling Show recreates the password box's handle.
        $r.Hk.Tag = '(click, then press keys)'
        foreach ($tb in @($r.Pw, $r.Hk)) {
            $tb.Add_HandleCreated({ param($s, $e) [PwPaste.Sender]::SetCue($s.Handle, [string]$s.Tag) })
        }

        $r.Pw.Add_TextChanged({
            if ($r.Filling) { return }
            $r.Revealed = $false                        # edited: it's a new password now
            if ($r.Pw.Text.Length -gt 0) { $r.Forget = $false }
        }.GetNewClosure())

        # Show: reveal the saved password (the window is behind the Windows
        # sign-in). Unticking - or the window locking - hides it again.
        $r.Show.Add_CheckedChanged({
            if ($r.Show.Checked) {
                if ($r.Pw.TextLength -eq 0 -and -not $r.Forget) {
                    $st2 = Get-PwState
                    $slot = $st2.Slots | Where-Object { $_.Index -eq $r.Index } | Select-Object -First 1
                    if ($slot -and $slot.Secret -and $slot.Secret.Length -gt 0) {
                        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($slot.Secret)
                        try {
                            $r.Filling = $true
                            $r.Pw.Text = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
                            $r.Revealed = $true
                        }
                        finally { $r.Filling = $false; [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
                    }
                }
                $r.Pw.UseSystemPasswordChar = $false
            }
            else {
                $r.Pw.UseSystemPasswordChar = $true
                if ($r.Revealed) { $r.Filling = $true; $r.Pw.Text = ''; $r.Filling = $false; $r.Revealed = $false }
            }
        }.GetNewClosure())

        $r.Hk.Add_Enter({ Set-PwSuspended -App $App -Suspended $true }.GetNewClosure())
        $r.Hk.Add_Leave({ Set-PwSuspended -App $App -Suspended $false }.GetNewClosure())
        $r.Hk.Add_PreviewKeyDown({ param($s, $e) if ($e.KeyCode -ne 'Tab') { $e.IsInputKey = $true } })
        $r.Hk.Add_KeyDown({
            param($s, $e)
            $e.SuppressKeyPress = $true; $e.Handled = $true
            $mods = [int]($e.KeyData -band [System.Windows.Forms.Keys]::Modifiers)
            if ($mods -eq 0 -and $e.KeyCode.ToString() -in @('Back', 'Delete', 'Escape')) {
                $r.Mods = 0; $r.Key = 0; & $setHotkeyText $r; return
            }
            $hk = ConvertFrom-PwKeyData -KeyData $e.KeyData -WinDown ([PwPaste.Sender]::IsWinDown())
            if (-not $hk) { return }   # only modifiers held so far
            if (-not (Test-PwHotkeyAllowed -Modifiers $hk.Modifiers -Key $hk.Key)) {
                $msg.ForeColor = [System.Drawing.Color]::FromArgb(190, 40, 40)
                $msg.Text = 'A hotkey needs Ctrl, Alt or Win (or use F13-F24).'
                return
            }
            $r.Mods = $hk.Modifiers; $r.Key = $hk.Key
            & $setHotkeyText $r
            $msg.Text = ''
        }.GetNewClosure())
    }

    # ---- save / revert ----
    $btnSave.Add_Click({
        $st2 = Get-PwState
        $new = @()
        $problems = @()
        foreach ($i2 in 1..5) {
            $r = $rows[$i2]
            $old = $st2.Slots | Where-Object { $_.Index -eq $i2 } | Select-Object -First 1
            $secret = $old.Secret
            if ($r.Forget) { $secret = $null }
            if ($r.Pw.Text.Length -gt 0 -and -not $r.Revealed) {   # revealed-and-unchanged = keep the saved one
                $secret = New-Object System.Security.SecureString
                foreach ($ch in $r.Pw.Text.ToCharArray()) { $secret.AppendChar($ch) }
                $secret.MakeReadOnly()
            }
            $name = $r.Name.Text.Trim(); if (-not $name) { $name = "Password $i2" }
            if ($r.On.Checked -and (-not $secret -or $secret.Length -eq 0)) { $problems += "$name has no password" }
            if ($r.On.Checked -and $r.Key -le 0) { $problems += "$name has no hotkey" }
            $new += [pscustomobject]@{
                Index = $i2; Name = $name; Secret = $secret
                Modifiers = $r.Mods; Key = $r.Key
                Enabled = $r.On.Checked; SendEnter = $r.Enter.Checked
                Method = $(if ($r.Method.SelectedItem) { [string]$r.Method.SelectedItem } else { 'Type' })
            }
        }
        $st2.Options.MinimizeToTray = $chkTray.Checked
        $st2.Options.StartPaused = $chkPaused.Checked
        $st2.Options.LockAfterMinutes = [int]$numLock.Value
        try {
            Save-PwSlots -App $App -Slots $new
            Update-PwHotkeys -App $App
            & $loadForm
            Resolve-PwOtherCopies -App $App -Owner $global:AppForm
            $msg.ForeColor = [System.Drawing.Color]::FromArgb(30, 130, 60)
            $msg.Text = 'Saved ' + (Get-Date).ToString('HH:mm:ss') + $(if ($problems) { '  -  not active: ' + ($problems -join '; ') } else { '' })
            $App.SetStatus('Password slots saved.', 'ok')
        }
        catch {
            $msg.ForeColor = [System.Drawing.Color]::FromArgb(190, 40, 40)
            $msg.Text = "Save failed: $($_.Exception.Message)"
            $App.Log('ERROR', 'PwPaste', "Save failed: $($_.Exception.Message)")
        }
    }.GetNewClosure())

    $btnRevert.Add_Click({ & $loadForm; $msg.ForeColor = $T.Muted; $msg.Text = 'Reverted to the saved settings.' }.GetNewClosure())

    Register-PwStateChangedHandler -Handler $refreshStatus
    Register-PwStateChangedHandler -Handler ({
        if ((Get-PwState).WindowLocked) { foreach ($i2 in 1..5) { if ($rows[$i2].Show.Checked) { $rows[$i2].Show.Checked = $false } } }
    }.GetNewClosure())

    # Alt-tabbing away while a hotkey box has focus fires no Leave - so release
    # the suspension when the window loses focus, and re-apply it on return.
    $hkBoxes = @(foreach ($i in 1..5) { $rows[$i].Hk })
    if ($global:AppForm) {
        $global:AppForm.Add_Deactivate({ Set-PwSuspended -App $App -Suspended $false }.GetNewClosure())
        $global:AppForm.Add_Activated({
            if (@($hkBoxes | Where-Object { $_.Focused }).Count -gt 0) { Set-PwSuspended -App $App -Suspended $true }
        }.GetNewClosure())
    }

    # Dock=Top stacks in reverse add order
    $Page.AutoScroll = $true
    $Page.Controls.Add($notes)
    $Page.Controls.Add($btns)
    $Page.Controls.Add($opt)
    $Page.Controls.Add($grid)
    $Page.Controls.Add($sub)
    $Page.Controls.Add($hdr)

    & $loadForm
    & $refreshStatus
}
