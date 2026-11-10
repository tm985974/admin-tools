# UI_Tab_Overview.psm1   (BASE TIER, project-owned)
#
# PDubPaste home: pause/resume, the 5 slots with their hotkeys and live
# status, the last thing sent, and how to use it.

function New-OverviewTab {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.TabPage]$Page,
        [Parameter(Mandatory)] $App
    )
    $T = $App.Theme

    $header = New-Object System.Windows.Forms.Label
    $header.Text = 'PDubPaste'; $header.Dock = 'Top'; $header.Height = 32
    Set-HeaderStyle -App $App -Label $header; $header.AutoSize = $false

    $sub = New-Object System.Windows.Forms.Label
    $sub.Dock = 'Top'; $sub.Height = 24; $sub.ForeColor = $T.Muted
    $sub.Text = 'Put the cursor where the password goes, then press its hotkey. Set passwords and hotkeys on the Password Config tab.'

    # ---- pause row ----
    $row = New-Object System.Windows.Forms.FlowLayoutPanel
    $row.Dock = 'Top'; $row.AutoSize = $true; $row.WrapContents = $false
    $row.Padding = New-Object System.Windows.Forms.Padding(0, 6, 0, 8)
    $btnPause = $T.MakeButton('Pause hotkeys')
    $btnPause.AutoSize = $false; $btnPause.Size = New-Object System.Drawing.Size(150, 32)
    $state = New-Object System.Windows.Forms.Label
    $state.AutoSize = $true; $state.Margin = New-Object System.Windows.Forms.Padding(12, 8, 3, 3)
    $state.Font = New-AppFont -App $App -Size ($T.FontSizePt + 1) -Style ([System.Drawing.FontStyle]::Bold)
    $row.Controls.Add($btnPause); $row.Controls.Add($state)

    # ---- slot list ----
    $list = New-Object System.Windows.Forms.ListView
    $list.Dock = 'Top'; $list.Height = 150; $list.View = 'Details'; $list.FullRowSelect = $true
    $list.HeaderStyle = 'Nonclickable'; $list.MultiSelect = $false; $list.HideSelection = $true
    foreach ($c in @(@('#', 34), @('Name', 200), @('Hotkey', 160), @('Method', 90), @('Enter after', 90), @('Status', 260))) {
        [void]$list.Columns.Add($c[0], $c[1])
    }

    $last = New-Object System.Windows.Forms.Label
    $last.Dock = 'Top'; $last.Height = 30; $last.ForeColor = $T.Muted
    $last.Padding = New-Object System.Windows.Forms.Padding(0, 8, 0, 0)

    $help = New-Object System.Windows.Forms.Label
    $help.Dock = 'Top'; $help.AutoSize = $false; $help.Height = 190; $help.ForeColor = $T.Text
    $help.Padding = New-Object System.Windows.Forms.Padding(0, 8, 0, 0)
    $b = [char]0x2022
    $help.Text = @(
        "$b  Hotkeys work in any app while this window is open, minimized, or in the tray."
        "$b  Nothing is sent into this app's own window - click into the target first."
        "$b  Hold the hotkey, then let go: the password is sent once all keys are released."
        "$b  If a slot says 'Hotkey in use by another app', pick a different combo."
        "$b  Windows blocks sending keys into programs running as administrator unless this app is too."
        "$b  Passwords are DPAPI-encrypted for your Windows account and never written to the logs."
        "$b  Opening the window asks for Windows Hello or your Windows password; minimizing or idling locks it again."
        "$b  Closing the window (X or tray > Exit) stops the hotkeys. Starting it again just shows the running copy."
    ) -join "`r`n"

    $refresh = {
        $st = Get-PwState
        $btnPause.Text = $(if ($st.Paused) { 'Resume hotkeys' } else { 'Pause hotkeys' })
        $active = @($st.Status.Values | Where-Object { $_ -eq 'Active' }).Count
        if ($st.Paused)        { $state.Text = 'PAUSED - no hotkeys are active'; $state.ForeColor = [System.Drawing.Color]::FromArgb(190, 110, 0) }
        elseif ($st.Suspended) { $state.Text = 'Editing a hotkey - hotkeys are off until you leave the box'; $state.ForeColor = $T.Muted }
        elseif ($active -gt 0) { $state.Text = "Listening - $active hotkey(s) active"; $state.ForeColor = [System.Drawing.Color]::FromArgb(30, 130, 60) }
        else                   { $state.Text = 'No hotkeys active - set one up on Password Config'; $state.ForeColor = $T.Muted }

        $list.BeginUpdate()
        $list.Items.Clear()
        foreach ($s in $st.Slots) {
            $it = New-Object System.Windows.Forms.ListViewItem ([string]$s.Index)
            [void]$it.SubItems.Add([string]$s.Name)
            [void]$it.SubItems.Add((Format-PwHotkey -Modifiers $s.Modifiers -Key $s.Key))
            [void]$it.SubItems.Add([string]$s.Method)
            [void]$it.SubItems.Add($(if ($s.SendEnter) { 'Yes' } else { '' }))
            $stat = [string]$st.Status[[int]$s.Index]
            [void]$it.SubItems.Add($stat)
            if ($stat -eq 'Active') { $it.ForeColor = $T.Text } else { $it.ForeColor = $T.Muted }
            [void]$list.Items.Add($it)
        }
        $list.EndUpdate()
        $last.Text = $(if ($st.LastMessage) { 'Last: ' + $st.LastMessage } else { 'Nothing sent yet this session.' })
    }.GetNewClosure()

    $btnPause.Add_Click({
        $st = Get-PwState
        Set-PwPaused -App $App -Paused (-not $st.Paused)
    }.GetNewClosure())

    Register-PwStateChangedHandler -Handler $refresh

    $Page.Controls.Add($help)
    $Page.Controls.Add($last)
    $Page.Controls.Add($list)
    $Page.Controls.Add($row)
    $Page.Controls.Add($sub)
    $Page.Controls.Add($header)
    & $refresh
}
