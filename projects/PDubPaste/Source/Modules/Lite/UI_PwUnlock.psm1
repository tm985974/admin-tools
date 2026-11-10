# UI_PwUnlock.psm1   (LITE TIER)
#
# The Windows-password unlock box (used when Windows Hello is unavailable or
# cancelled). Returns 'Verified', 'Hello' (switch to Windows Hello) or 'Cancel'.
# After 3 wrong passwords it closes, so it can't run a domain account into its
# lockout limit by itself.

function Show-PwPasswordDialog {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, $Owner, [bool]$HelloAvailable = $false)
    $T = $App.Theme
    $red = [System.Drawing.Color]::FromArgb(190, 40, 40)

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'PDubPaste - unlock'
    $dlg.FormBorderStyle = 'FixedDialog'; $dlg.MinimizeBox = $false; $dlg.MaximizeBox = $false
    $dlg.ShowInTaskbar = $false; $dlg.TopMost = $true
    $dlg.StartPosition = $(if ($Owner -and $Owner.Visible) { 'CenterParent' } else { 'CenterScreen' })
    $dlg.ClientSize = New-Object System.Drawing.Size(430, 196)
    $dlg.Font = New-Object System.Drawing.Font($T.FontName, $T.FontSizePt)
    $dlg.BackColor = $T.Panel

    $title = New-Object System.Windows.Forms.Label
    $title.Text = 'Enter your Windows password to unlock'
    $title.Location = New-Object System.Drawing.Point(16, 14); $title.AutoSize = $true
    $title.ForeColor = $T.Title; $title.Font = New-Object System.Drawing.Font($T.FontName, ($T.FontSizePt + 1), [System.Drawing.FontStyle]::Bold)

    $acct = New-Object System.Windows.Forms.Label
    $acct.Text = 'Account: ' + [PwPaste.WinAuth]::CurrentUserName()
    $acct.Location = New-Object System.Drawing.Point(16, 42); $acct.AutoSize = $true; $acct.ForeColor = $T.Muted

    $txt = New-Object System.Windows.Forms.TextBox
    $txt.UseSystemPasswordChar = $true
    $txt.Location = New-Object System.Drawing.Point(16, 68); $txt.Width = 398

    $err = New-Object System.Windows.Forms.Label
    $err.Location = New-Object System.Drawing.Point(16, 100); $err.Size = New-Object System.Drawing.Size(398, 40)
    $err.ForeColor = $red

    $btnOk = $T.MakeButton('Unlock')
    $btnOk.AutoSize = $false; $btnOk.Size = New-Object System.Drawing.Size(96, 30)
    $btnOk.Location = New-Object System.Drawing.Point(318, 150)

    $btnCancel = $T.MakeButton('Cancel')
    $btnCancel.AutoSize = $false; $btnCancel.Size = New-Object System.Drawing.Size(96, 30)
    $btnCancel.Location = New-Object System.Drawing.Point(214, 150)
    $btnCancel.DialogResult = 'Cancel'

    $dlg.Controls.AddRange(@($title, $acct, $txt, $err, $btnOk, $btnCancel))
    $dlg.AcceptButton = $btnOk; $dlg.CancelButton = $btnCancel

    $res = @{ Value = 'Cancel'; Fails = 0 }

    if ($HelloAvailable) {
        $btnHello = $T.MakeButton('Use Windows Hello')
        $btnHello.AutoSize = $false; $btnHello.Size = New-Object System.Drawing.Size(150, 30)
        $btnHello.Location = New-Object System.Drawing.Point(16, 150)
        $btnHello.Add_Click({ $res.Value = 'Hello'; $dlg.Close() }.GetNewClosure())
        $dlg.Controls.Add($btnHello)
    }

    $btnOk.Add_Click({
        if ($txt.TextLength -eq 0) { $err.Text = 'Type your Windows password.'; return }
        $ss = New-Object System.Security.SecureString
        foreach ($ch in $txt.Text.ToCharArray()) { $ss.AppendChar($ch) }
        $txt.Clear()
        $dlg.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try { $ok = [PwPaste.WinAuth]::VerifyCurrentUser($ss) } finally { $ss.Dispose(); $dlg.Cursor = [System.Windows.Forms.Cursors]::Default }
        if ($ok) { $res.Value = 'Verified'; $dlg.Close(); return }

        $res.Fails++
        $code = [PwPaste.WinAuth]::LastError
        $App.Log('WARN', 'PwUnlock', "Windows password check failed (Win32 $code), attempt $($res.Fails).")
        $why = switch ($code) {
            1909    { 'Windows says this account is locked out.' }
            1327    { 'Windows refused the sign-in (account restriction, e.g. a blank password).' }
            1311    { 'No sign-in server is available to check the password right now.' }
            default { "That isn't the Windows password for this account." }
        }
        if ($res.Fails -ge 3) {
            [void][System.Windows.Forms.MessageBox]::Show($dlg, "$why`r`n`r`nToo many attempts - the window stays locked.", 'PDubPaste',
                'OK', 'Warning')
            $dlg.Close(); return
        }
        $err.Text = "$why  ($(3 - $res.Fails) attempt(s) left)"
        $txt.Focus()
    }.GetNewClosure())

    $dlg.Add_Shown({ $dlg.Activate(); [void][PwPaste.Lifetime]::BringToFront($dlg.Handle); $txt.Focus() }.GetNewClosure())
    if ($Owner -and $Owner.Visible) { [void]$dlg.ShowDialog($Owner) } else { [void]$dlg.ShowDialog() }
    $dlg.Dispose()
    return $res.Value
}
