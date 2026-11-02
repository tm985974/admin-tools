# UI_RunDialog.psm1   (LITE TIER)
#
#   $req = Show-LibraryRunDialog -App $App -Entry $entry -Owner $form
#
# Builds the prompt from the function's own param() block (or, for a Command
# entry, the param() block that declares its template fields): a text box per
# value, a check box per switch, a drop-down per ValidateSet, a list box for
# arrays, a Set... button for credentials. Values start from the last run of
# this entry, then the active environment (Domain, Server, SearchBase ...).
# The exact command line is previewed live. A strip under the title says
# whether the entry will run here (or which fallback it will use); Check now
# tests the computers in the target fields / remote list (DNS + the ports the
# command uses) without running anything. Run returns
#   CallText, Variables (credentials, passed in memory - never in the text),
#   Targets (remote computers, or none), RemoteCredential, WhatIf,
#   Plan (methods: primary + fallbacks), Hosts, PreCheck, Fallback
# or $null on Cancel.
#
#   $cred = Show-LibraryCredentialDialog -App $App -Title '...' [-UserName x]

function Show-LibraryCredentialDialog {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [string]$Title = 'Credentials', [string]$UserName = '', $Owner = $null)

    $f = New-Object System.Windows.Forms.Form
    $f.Text = $Title; $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false
    $f.StartPosition = 'CenterParent'; $f.ClientSize = New-Object System.Drawing.Size(420, 150)
    $f.Font = New-AppFont -App $App; $f.ShowInTaskbar = $false

    $l1 = New-Object System.Windows.Forms.Label; $l1.Text = 'User name'; $l1.Location = New-Object System.Drawing.Point(14, 20); $l1.AutoSize = $true
    $tU = New-Object System.Windows.Forms.TextBox; $tU.Location = New-Object System.Drawing.Point(110, 16); $tU.Width = 290; $tU.Text = $UserName
    $l2 = New-Object System.Windows.Forms.Label; $l2.Text = 'Password'; $l2.Location = New-Object System.Drawing.Point(14, 56); $l2.AutoSize = $true
    $tP = New-Object System.Windows.Forms.TextBox; $tP.Location = New-Object System.Drawing.Point(110, 52); $tP.Width = 290; $tP.UseSystemPasswordChar = $true
    $hint = New-Object System.Windows.Forms.Label; $hint.Text = 'DOMAIN\user or user@domain. Kept in memory for this run only.'
    $hint.Location = New-Object System.Drawing.Point(110, 80); $hint.AutoSize = $true; $hint.ForeColor = $App.Theme.Muted
    $ok = $App.Theme.MakeButton('OK'); $ok.Location = New-Object System.Drawing.Point(234, 108); $ok.DialogResult = 'OK'
    $cancel = $App.Theme.MakeButton('Cancel'); $cancel.Location = New-Object System.Drawing.Point(318, 108); $cancel.DialogResult = 'Cancel'
    $f.Controls.AddRange(@($l1, $tU, $l2, $tP, $hint, $ok, $cancel))
    $f.AcceptButton = $ok; $f.CancelButton = $cancel
    $f.Add_Shown({ if ($tU.Text) { [void]$tP.Focus() } else { [void]$tU.Focus() } }.GetNewClosure())

    $r = if ($Owner) { $f.ShowDialog($Owner) } else { $f.ShowDialog() }
    $cred = $null
    if ($r -eq 'OK' -and $tU.Text.Trim()) {
        $sec = New-Object System.Security.SecureString
        foreach ($ch in $tP.Text.ToCharArray()) { $sec.AppendChar($ch) }
        $sec.MakeReadOnly()
        $cred = New-Object System.Management.Automation.PSCredential($tU.Text.Trim(), $sec)
    }
    $tP.Text = ''
    $f.Dispose()
    return $cred
}

function Show-LibraryRunDialog {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $App, [Parameter(Mandatory)] $Entry, $Owner = $null, $Readiness = $null)

    $params = @(Get-LibraryEntryParameters -Entry $Entry)
    $help = Get-LibraryEntryHelp -Entry $Entry
    $canWhatIf = Test-LibraryEntryWhatIf -Entry $Entry
    $isCommand = Test-LibraryCommandEntry $Entry
    $last = Get-LibraryLastValues -App $App -Id $Entry.Id

    $d = @{ App = $App; Entry = $Entry; Params = $params; Inputs = @{}; Creds = @{}; Result = $null; CanWhatIf = $canWhatIf; Readiness = $Readiness }

    $f = New-Object System.Windows.Forms.Form
    $f.Text = "Run - $($Entry.Name)"; $f.StartPosition = 'CenterParent'; $f.ShowInTaskbar = $false
    $f.Font = New-AppFont -App $App; $f.MinimizeBox = $false; $f.BackColor = $App.Theme.Surface
    $f.MinimumSize = New-Object System.Drawing.Size(760, 460)
    $f.Size = New-Object System.Drawing.Size(980, [Math]::Min(900, 360 + 52 * [Math]::Max(1, $params.Count)))
    $d.Form = $f

    # ---- header
    $head = New-Object System.Windows.Forms.Panel
    $head.Dock = 'Top'; $head.Padding = New-Object System.Windows.Forms.Padding(14, 10, 14, 6)
    $hdr = New-Object System.Windows.Forms.Label
    $hdr.Text = $Entry.Name; $hdr.Dock = 'Top'; $hdr.Height = 30
    Set-HeaderStyle -App $App -Label $hdr; $hdr.AutoSize = $false
    $desc = New-Object System.Windows.Forms.Label
    $desc.Dock = 'Top'; $desc.AutoSize = $false; $desc.ForeColor = $App.Theme.Text
    $dtext = [string]$Entry.Description
    if (-not $dtext.Trim()) { $dtext = $help.Synopsis }
    if ($Entry.WhereToRun) { $dtext = $dtext.Trim() + "`r`nWhere to run: " + ([string]$Entry.WhereToRun).Trim() }
    $desc.Text = $dtext.Trim(); $desc.Height = [Math]::Min(80, 20 * [Math]::Max(1, ($desc.Text -split "`n").Count + [int]($desc.Text.Length / 130)))
    $head.Controls.Add($desc); $head.Controls.Add($hdr)
    if ($Entry.Modifies) {
        $warn = New-Object System.Windows.Forms.Label
        $warn.Dock = 'Top'; $warn.Height = 28; $warn.TextAlign = 'MiddleLeft'; $warn.Padding = New-Object System.Windows.Forms.Padding(8, 0, 0, 0)
        $warn.BackColor = [System.Drawing.Color]::FromArgb(255, 236, 214); $warn.ForeColor = [System.Drawing.Color]::FromArgb(150, 60, 0)
        $warn.Text = 'This command CHANGES things. Check the command below before you run it.' + $(if ($canWhatIf) { '  (WhatIf shows what would change without changing it.)' })
        $head.Controls.Add($warn); $warn.BringToFront()
    }
    # will it run here?
    $rdy = New-Object System.Windows.Forms.Label
    $rdy.Dock = 'Top'; $rdy.Height = 26; $rdy.TextAlign = 'MiddleLeft'; $rdy.Padding = New-Object System.Windows.Forms.Padding(8, 0, 0, 0)
    $rdy.AutoEllipsis = $true
    $head.Controls.Add($rdy); $rdy.BringToFront()
    $d.ReadyLabel = $rdy
    Set-LibraryRunReadyStrip -Dialog $d -Remote:$false
    $head.Height = 16 + $hdr.Height + $desc.Height + $(if ($Entry.Modifies) { 32 } else { 0 }) + 30

    # ---- parameters
    $scroll = New-Object System.Windows.Forms.Panel
    $scroll.Dock = 'Fill'; $scroll.AutoScroll = $true; $scroll.Padding = New-Object System.Windows.Forms.Padding(14, 4, 14, 4)
    $grid = New-Object System.Windows.Forms.TableLayoutPanel
    $grid.ColumnCount = 3; $grid.AutoSize = $true; $grid.AutoSizeMode = 'GrowAndShrink'; $grid.Dock = 'Top'
    [void]$grid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Absolute', 190)))
    [void]$grid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Absolute', 380)))
    [void]$grid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
    $scroll.Controls.Add($grid)

    if ($params.Count -eq 0) {
        $none = New-Object System.Windows.Forms.Label
        $none.Text = 'This command takes no parameters.'; $none.AutoSize = $true; $none.ForeColor = $App.Theme.Muted
        $grid.Controls.Add($none, 0, 0); $grid.SetColumnSpan($none, 3)
    }

    $row = 0
    foreach ($p in $params) {
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = $p.Name + $(if ($p.Mandatory) { ' *' })
        $lbl.AutoSize = $true; $lbl.Margin = New-Object System.Windows.Forms.Padding(0, 8, 6, 4)
        if ($p.Mandatory) { $lbl.Font = New-AppFont -App $App -Style ([System.Drawing.FontStyle]::Bold) }

        # starting value: last run > environment > (function default applies when left empty)
        $start = $null
        if ($last.ContainsKey($p.Name)) { $start = $last[$p.Name] }
        elseif ($p.Kind -notin @('Switch', 'Bool', 'Credential', 'SecureString')) {
            $envv = Get-LibraryEnvironmentDefault -App $App -Name $p.Name
            if ($envv) { $start = $envv }
        }
        # a command template has no function to apply defaults: show them in the box
        if ($null -eq $start -and $isCommand) { $start = Get-LibraryTemplateDefault -Param $p }

        $ctl = $null
        switch ($p.Kind) {
            'Switch' {
                $ctl = New-Object System.Windows.Forms.CheckBox
                $ctl.Text = 'On'; $ctl.AutoSize = $true; $ctl.Checked = ($start -eq $true)
                if ($p.DefaultText -match '^\$true$') { $ctl.Checked = $true }
                if ($null -ne $start) { $ctl.Checked = [bool]$start }
            }
            'Bool' {
                $ctl = New-Object System.Windows.Forms.ComboBox
                $ctl.DropDownStyle = 'DropDownList'; $ctl.Width = 120
                [void]$ctl.Items.AddRange(@('', 'True', 'False'))
                $ctl.SelectedIndex = 0
                if ($null -ne $start -and [string]$start -ne '') { $ctl.SelectedItem = $(if ([string]$start -match '^(true|1)$') { 'True' } else { 'False' }) }
            }
            'Credential' {
                $ctl = New-Object System.Windows.Forms.FlowLayoutPanel
                $ctl.AutoSize = $true; $ctl.WrapContents = $false
                $b = $App.Theme.MakeButton('Set...')
                $s = New-Object System.Windows.Forms.Label
                $s.AutoSize = $true; $s.Margin = New-Object System.Windows.Forms.Padding(8, 8, 0, 0); $s.ForeColor = $App.Theme.Muted
                $s.Text = '(not set - runs as you)'
                $ctl.Controls.Add($b); $ctl.Controls.Add($s)
                $pname = $p.Name
                $b.Add_Click({
                    $cur = $d.Creds[$pname]
                    $c = Show-LibraryCredentialDialog -App $d.App -Title "Credential for -$pname" -UserName $(if ($cur) { $cur.UserName } else { '' }) -Owner $d.Form
                    if ($c) { $d.Creds[$pname] = $c; $s.Text = $c.UserName; $s.ForeColor = $d.App.Theme.Text }
                    else { $d.Creds.Remove($pname); $s.Text = '(not set - runs as you)'; $s.ForeColor = $d.App.Theme.Muted }
                    Update-LibraryRunPreview -Dialog $d
                }.GetNewClosure())
            }
            'SecureString' {
                $ctl = New-Object System.Windows.Forms.TextBox
                $ctl.Width = 360; $ctl.UseSystemPasswordChar = $true
            }
            'StringArray' {
                $ctl = New-Object System.Windows.Forms.TextBox
                $ctl.Width = 360; $ctl.Height = 72; $ctl.Multiline = $true; $ctl.ScrollBars = 'Vertical'; $ctl.AcceptsReturn = $true
                if ($null -ne $start) { $ctl.Text = ((@($start) | ForEach-Object { [string]$_ }) -join "`r`n") -replace '(?<!\r)\n', "`r`n" }
            }
            default {
                if (@($p.ValidateSet).Count -gt 0) {
                    $ctl = New-Object System.Windows.Forms.ComboBox
                    $ctl.DropDownStyle = 'DropDownList'; $ctl.Width = 360
                    if (-not $p.Mandatory) { [void]$ctl.Items.Add('') }
                    foreach ($v in $p.ValidateSet) { [void]$ctl.Items.Add($v) }
                    $sel = if ($null -ne $start) { [string]$start } else { ([string]$p.DefaultText).Trim("'", '"') }
                    $i = $ctl.Items.IndexOf($sel)
                    $ctl.SelectedIndex = $(if ($i -ge 0) { $i } else { 0 })
                }
                else {
                    $ctl = New-Object System.Windows.Forms.TextBox
                    $ctl.Width = 360
                    if ($null -ne $start) { $ctl.Text = [string]$start }
                }
            }
        }
        $ctl.Margin = New-Object System.Windows.Forms.Padding(0, 4, 8, 4)

        $hl = New-Object System.Windows.Forms.Label
        $hl.AutoSize = $true; $hl.MaximumSize = New-Object System.Drawing.Size(420, 0); $hl.ForeColor = $App.Theme.Muted
        $hl.Margin = New-Object System.Windows.Forms.Padding(0, 8, 0, 4)
        $bits = @("[$($p.TypeName)]")
        if ($p.DefaultText) { $bits += "default $($p.DefaultText)" }
        if ($p.Kind -eq 'StringArray') { $bits += 'one per line' }
        if ($p.HelpText) { $bits += $p.HelpText }
        if ($null -ne $start -and -not $last.ContainsKey($p.Name) -and $p.Kind -notin @('Switch', 'Bool') -and -not ($isCommand -and [string]$start -eq [string](Get-LibraryTemplateDefault -Param $p))) { $bits += '(from environment)' }
        $hl.Text = $bits -join '  -  '

        $grid.RowCount = $row + 1
        $grid.Controls.Add($lbl, 0, $row); $grid.Controls.Add($ctl, 1, $row); $grid.Controls.Add($hl, 2, $row)
        $d.Inputs[$p.Name] = $ctl
        $row++
    }

    # ---- bottom: where, whatif, preview, buttons
    $bottom = New-Object System.Windows.Forms.Panel
    $bottom.Dock = 'Bottom'; $bottom.Height = 292; $bottom.Padding = New-Object System.Windows.Forms.Padding(14, 6, 14, 10)

    $rbLocal = New-Object System.Windows.Forms.RadioButton
    $rbLocal.Text = 'Run on this computer'; $rbLocal.AutoSize = $true; $rbLocal.Location = New-Object System.Drawing.Point(14, 8); $rbLocal.Checked = $true
    $rbRemote = New-Object System.Windows.Forms.RadioButton
    $rbRemote.Text = 'Run on these computers (remoting):'; $rbRemote.AutoSize = $true; $rbRemote.Location = New-Object System.Drawing.Point(14, 32)
    $txtTargets = New-Object System.Windows.Forms.TextBox
    $txtTargets.Multiline = $true; $txtTargets.ScrollBars = 'Vertical'; $txtTargets.Location = New-Object System.Drawing.Point(34, 56)
    $txtTargets.Size = New-Object System.Drawing.Size(300, 64); $txtTargets.Enabled = $false; $txtTargets.AcceptsReturn = $true
    $chkRemoteCred = New-Object System.Windows.Forms.CheckBox
    $chkRemoteCred.Text = 'Connect with other credentials'; $chkRemoteCred.AutoSize = $true; $chkRemoteCred.Location = New-Object System.Drawing.Point(344, 56); $chkRemoteCred.Enabled = $false
    $chkWhatIf = New-Object System.Windows.Forms.CheckBox
    $chkWhatIf.Text = 'WhatIf - show what would change, change nothing'; $chkWhatIf.AutoSize = $true; $chkWhatIf.Location = New-Object System.Drawing.Point(344, 8)
    $chkWhatIf.Visible = $canWhatIf; $chkWhatIf.Checked = ($canWhatIf -and $Entry.Modifies)
    $chkPre = New-Object System.Windows.Forms.CheckBox
    $chkPre.Text = 'Check the target answers before running'; $chkPre.AutoSize = $true; $chkPre.Location = New-Object System.Drawing.Point(344, 32); $chkPre.Checked = $true
    $btnCheck = $App.Theme.MakeButton('Check now'); $btnCheck.Location = New-Object System.Drawing.Point(344, 86)
    $tipPre = New-Object System.Windows.Forms.ToolTip
    $tipPre.SetToolTip($chkPre, 'Before running: the computers in the target fields (or the remote list) must resolve in DNS and answer on the port the command uses. Saves waiting for a timeout.')
    $tipPre.SetToolTip($btnCheck, 'Test DNS and the ports now, without running anything.')
    if (-not $Entry.RemoteCapable) { $rbRemote.Enabled = $false; $rbRemote.Text = 'Run on other computers (not available for this entry)' }
    if ($last.ContainsKey('__Targets')) { $txtTargets.Text = ((@($last['__Targets']) | ForEach-Object { [string]$_ }) -join "`r`n") }

    $lblPrev = New-Object System.Windows.Forms.Label
    $lblPrev.Text = 'Command'; $lblPrev.AutoSize = $true; $lblPrev.Location = New-Object System.Drawing.Point(14, 128)
    $txtPrev = New-Object System.Windows.Forms.TextBox
    $txtPrev.Multiline = $true; $txtPrev.ReadOnly = $true; $txtPrev.ScrollBars = 'Vertical'; $txtPrev.Font = New-LibraryMonoFont -App $App
    $txtPrev.Location = New-Object System.Drawing.Point(14, 148); $txtPrev.Height = 48; $txtPrev.Anchor = 'Top,Left,Right'
    $txtPrev.BackColor = [System.Drawing.Color]::White
    $txtCheck = New-Object System.Windows.Forms.TextBox
    $txtCheck.Multiline = $true; $txtCheck.ReadOnly = $true; $txtCheck.ScrollBars = 'Vertical'; $txtCheck.BorderStyle = 'None'
    $txtCheck.Location = New-Object System.Drawing.Point(14, 202); $txtCheck.Height = 44; $txtCheck.Anchor = 'Top,Left,Right'
    $txtCheck.BackColor = $App.Theme.Surface; $txtCheck.ForeColor = $App.Theme.Text
    $lblErr = New-Object System.Windows.Forms.Label
    $lblErr.AutoSize = $false; $lblErr.Location = New-Object System.Drawing.Point(14, 200); $lblErr.Height = 22; $lblErr.Anchor = 'Top,Left,Right'
    $lblErr.ForeColor = [System.Drawing.Color]::Firebrick

    $btnCopy = $App.Theme.MakeButton('Copy command'); $btnCopy.Anchor = 'Bottom,Right'
    $btnRun = $App.Theme.MakeButton('Run'); $btnRun.Anchor = 'Bottom,Right'
    $btnCancel = $App.Theme.MakeButton('Cancel'); $btnCancel.Anchor = 'Bottom,Right'; $btnCancel.DialogResult = 'Cancel'
    $bottom.Controls.AddRange(@($rbLocal, $rbRemote, $txtTargets, $chkRemoteCred, $chkWhatIf, $chkPre, $btnCheck, $lblPrev, $txtPrev, $txtCheck, $lblErr, $btnCopy, $btnRun, $btnCancel))

    $f.Controls.Add($scroll)
    $f.Controls.Add($bottom)
    $f.Controls.Add($head)
    $f.CancelButton = $btnCancel

    $d.RbRemote = $rbRemote; $d.Targets = $txtTargets; $d.RemoteCred = $chkRemoteCred; $d.WhatIf = $chkWhatIf
    $d.Preview = $txtPrev; $d.Err = $lblErr; $d.BtnRun = $btnRun; $d.PreCheck = $chkPre; $d.CheckBox = $txtCheck; $d.BtnCheck = $btnCheck; $d.TipPre = $tipPre

    $layout = {
        $w = $bottom.ClientSize.Width
        $txtPrev.Width = $w - 28; $txtCheck.Width = $w - 28; $lblErr.Width = $w - 28 - 360
        $x = $w - 14
        foreach ($b in @($btnCancel, $btnRun, $btnCopy)) { $x -= $b.Width; $b.Location = New-Object System.Drawing.Point($x, ($bottom.ClientSize.Height - $b.Height - 8)); $x -= 8 }
        $lblErr.Width = [Math]::Max(100, $x - 24)
        $lblErr.Location = New-Object System.Drawing.Point(14, ($bottom.ClientSize.Height - 34))
    }.GetNewClosure()
    $bottom.Add_Resize($layout)

    # ---- events: every change refreshes the preview
    $refresh = { Update-LibraryRunPreview -Dialog $d }.GetNewClosure()
    foreach ($ctl in $d.Inputs.Values) {
        if ($ctl -is [System.Windows.Forms.TextBox]) { $ctl.Add_TextChanged($refresh) }
        elseif ($ctl -is [System.Windows.Forms.CheckBox]) { $ctl.Add_CheckedChanged($refresh) }
        elseif ($ctl -is [System.Windows.Forms.ComboBox]) { $ctl.Add_SelectedIndexChanged($refresh) }
    }
    $rbRemote.Add_CheckedChanged({
        $txtTargets.Enabled = $rbRemote.Checked; $chkRemoteCred.Enabled = $rbRemote.Checked
        Set-LibraryRunReadyStrip -Dialog $d -Remote:($rbRemote.Checked)
        Update-LibraryRunPreview -Dialog $d
    }.GetNewClosure())
    $btnCheck.Add_Click({ Invoke-LibraryRunCheck -Dialog $d | Out-Null }.GetNewClosure())
    $txtTargets.Add_TextChanged($refresh)
    $chkWhatIf.Add_CheckedChanged($refresh)

    $btnCopy.Add_Click({
        $t = $d.Preview.Text
        if ($t) { [System.Windows.Forms.Clipboard]::SetText($t) }
    }.GetNewClosure())

    $btnRun.Add_Click({
        $call = Update-LibraryRunPreview -Dialog $d
        if (-not $call -or @($call.Errors).Count) { return }
        $targets = @()
        if ($d.RbRemote.Checked) {
            $targets = @(Split-LibraryList $d.Targets.Text)
            if ($targets.Count -eq 0) { $d.Err.Text = 'Enter at least one computer, or choose this computer.'; return }
        }
        # known not to work here: say why before it fails
        if ($targets.Count -eq 0 -and $d.Readiness -and $d.Readiness.Level -eq 'Blocked') {
            $fix = @($d.Readiness.Lines | Where-Object { $_.Fix } | Select-Object -First 1 | ForEach-Object { "`r`n`r`nFix: $($_.Fix)" })
            $r = [System.Windows.Forms.MessageBox]::Show($d.Form, "This will not work on this computer: $($d.Readiness.Summary).$fix`r`n`r`nRun anyway?", 'Will fail here', 'YesNo', 'Warning', 'Button2')
            if ($r -ne 'Yes') { return }
            $d.Force = $true
        }
        if ($d.Entry.Modifies -and -not ($d.CanWhatIf -and $d.WhatIf.Checked)) {
            $where = if ($targets.Count) { "on $($targets.Count) computer(s)" } else { 'on this computer' }
            $r = [System.Windows.Forms.MessageBox]::Show($d.Form, "This command changes things. Run it $where now?`r`n`r`n$($call.Display)", 'Confirm run', 'YesNo', 'Warning', 'Button2')
            if ($r -ne 'Yes') { return }
        }
        $rcred = $null
        if ($targets.Count -and $d.RemoteCred.Checked) {
            $rcred = Show-LibraryCredentialDialog -App $d.App -Title 'Credentials for remoting' -Owner $d.Form
            if (-not $rcred) { return }
        }
        # remember values (never credentials / secure strings)
        $mem = @{}
        foreach ($p in $d.Params) {
            if ($p.Kind -in @('Credential', 'SecureString')) { continue }
            $mem[$p.Name] = Get-LibraryRunInputValue -Control $d.Inputs[$p.Name] -Param $p
        }
        if ($targets.Count) { $mem['__Targets'] = $targets } elseif ($d.Targets.Text.Trim()) { $mem['__Targets'] = @(Split-LibraryList $d.Targets.Text) }
        Set-LibraryLastValues -App $d.App -Id $d.Entry.Id -Values $mem

        $pl = Get-LibraryRunDialogPlan -Dialog $d -Call $call
        $d.Result = [pscustomobject]@{
            CallText = $call.Text; Variables = $pl.Variables; Targets = $targets
            RemoteCredential = $rcred; WhatIf = ($d.CanWhatIf -and $d.WhatIf.Checked)
            Plan = @($pl.Plan); Hosts = @($pl.Hosts); PreCheck = $d.PreCheck.Checked; Fallback = [bool]$pl.Fallback; Force = [bool]$d.Force
        }
        $d.Form.DialogResult = 'OK'
        $d.Form.Close()
    }.GetNewClosure())

    $f.Add_Shown({
        & $layout
        Update-LibraryRunPreview -Dialog $d | Out-Null
        $first = @($d.Inputs.Values | Where-Object { $_ -is [System.Windows.Forms.TextBox] -and -not $_.Text }) | Select-Object -First 1
        if ($first) { $first.Focus() | Out-Null }
    }.GetNewClosure())

    [void]$(if ($Owner) { $f.ShowDialog($Owner) } else { $f.ShowDialog() })
    $res = $d.Result
    $f.Dispose()
    return $res
}

function Get-LibraryRunInputValue {
    param($Control, $Param)
    switch ($Param.Kind) {
        'Switch' { return [bool]$Control.Checked }
        'Bool' { $s = [string]$Control.SelectedItem; if (-not $s) { return '' }; return ($s -eq 'True') }
        'Credential' { return $null }
        'SecureString' {
            if (-not $Control.Text) { return $null }
            $sec = New-Object System.Security.SecureString
            foreach ($ch in $Control.Text.ToCharArray()) { $sec.AppendChar($ch) }
            $sec.MakeReadOnly(); return $sec
        }
        default {
            if ($Control -is [System.Windows.Forms.ComboBox]) { return [string]$Control.SelectedItem }
            return [string]$Control.Text
        }
    }
}

function Update-LibraryRunPreview {
    param($Dialog)
    $vals = @{}
    foreach ($p in $Dialog.Params) {
        if ($p.Kind -eq 'Credential') { if ($Dialog.Creds.ContainsKey($p.Name)) { $vals[$p.Name] = $Dialog.Creds[$p.Name] }; continue }
        $v = Get-LibraryRunInputValue -Control $Dialog.Inputs[$p.Name] -Param $p
        if ($null -ne $v) { $vals[$p.Name] = $v }
    }
    $call = ConvertTo-LibraryEntryCall -Entry $Dialog.Entry -Parameters $Dialog.Params -Values $vals -WhatIf:($Dialog.CanWhatIf -and $Dialog.WhatIf.Checked)
    $text = $call.Display
    if ($Dialog.RbRemote.Checked) {
        $t = @(Split-LibraryList $Dialog.Targets.Text)
        $inner = if (Test-LibraryCommandEntry $Dialog.Entry) { $call.Display } else { "<$($Dialog.Entry.Function) and its helpers>; $($call.Display)" }
        $text = "Invoke-Command -ComputerName $(if ($t.Count) { ($t | ForEach-Object { ConvertTo-LibraryLiteral $_ }) -join ', ' } else { '<computers>' })$(if ($Dialog.RemoteCred.Checked) { ' -Credential <asked at run>' }) -ScriptBlock { $inner }"
    }
    $Dialog.Preview.Text = $text
    $msg = @($call.Errors)
    $Dialog.Err.Text = $(if ($msg.Count) { $msg -join '   |   ' } else { '' })
    $Dialog.BtnRun.Enabled = ($msg.Count -eq 0)
    return $call
}

# The strip under the title: ready / fallback / will fail, for here or remote.
function Set-LibraryRunReadyStrip {
    param($Dialog, [switch]$Remote)
    $l = $Dialog.ReadyLabel
    if (-not $l) { return }
    $rd = $Dialog.Readiness
    if ($Remote) {
        $l.BackColor = [System.Drawing.Color]::FromArgb(232, 240, 250); $l.ForeColor = [System.Drawing.Color]::FromArgb(30, 70, 120)
        $alts = @(Get-LibraryEntryMethods -Entry $Dialog.Entry).Count - 1
        $l.Text = 'Remote: each computer must answer on WinRM (TCP 5985) - checked first, unreachable ones are skipped.' + $(if ($alts -gt 0) { ' Fallbacks are tried on each computer.' })
        return
    }
    if (-not $rd -or $rd.Level -eq 'Unknown') {
        $l.BackColor = $Dialog.App.Theme.Surface; $l.ForeColor = $Dialog.App.Theme.Muted
        $l.Text = 'Still checking what this computer has...'
        return
    }
    $first = @($rd.Lines | Select-Object -First 1)
    switch ($rd.Level) {
        'Ready' {
            $l.BackColor = [System.Drawing.Color]::FromArgb(226, 244, 230); $l.ForeColor = [System.Drawing.Color]::FromArgb(20, 100, 40)
            $l.Text = $(if ($rd.Fallback) { "Ready here - will use the fallback '$($rd.MethodLabel)'. $(if ($first) { $first[0].Text })" } else { 'Ready on this computer.' + $(if (@($rd.Lines | Where-Object { $_.Kind -eq 'Target' }).Count) { ' The target is checked before it runs.' }) })
        }
        'Warn' {
            $l.BackColor = [System.Drawing.Color]::FromArgb(255, 244, 214); $l.ForeColor = [System.Drawing.Color]::FromArgb(130, 80, 0)
            $l.Text = "Check: $(if ($first) { $first[0].Text + ' ' + $first[0].Fix } else { $rd.Summary })"
        }
        default {
            $l.BackColor = [System.Drawing.Color]::FromArgb(253, 228, 228); $l.ForeColor = [System.Drawing.Color]::FromArgb(150, 20, 20)
            $l.Text = "Will not run here - $(if ($first) { $first[0].Text + $(if ($first[0].Fix) { '  Fix: ' + $first[0].Fix }) } else { $rd.Summary })"
        }
    }
    if (-not $Dialog.ReadyTip) { $Dialog.ReadyTip = New-Object System.Windows.Forms.ToolTip }
    $Dialog.ReadyTip.SetToolTip($l, ((@($rd.Lines) | ForEach-Object { "$($_.Kind): $($_.Text)$(if ($_.Fix) { "`r`n   Fix: $($_.Fix)" })" }) -join "`r`n"))
}

# Current values -> the run plan (methods with call text, hosts, merged variables).
function Get-LibraryRunDialogPlan {
    param($Dialog, $Call)
    $vals = @{}
    foreach ($p in $Dialog.Params) {
        if ($p.Kind -eq 'Credential') { if ($Dialog.Creds.ContainsKey($p.Name)) { $vals[$p.Name] = $Dialog.Creds[$p.Name] }; continue }
        $v = Get-LibraryRunInputValue -Control $Dialog.Inputs[$p.Name] -Param $p
        if ($null -ne $v) { $vals[$p.Name] = $v }
    }
    if (-not $Call) { $Call = ConvertTo-LibraryEntryCall -Entry $Dialog.Entry -Parameters $Dialog.Params -Values $vals -WhatIf:($Dialog.CanWhatIf -and $Dialog.WhatIf.Checked) }
    return (Get-LibraryRunPlan -Entry $Dialog.Entry -Parameters $Dialog.Params -Values $vals -Call $Call -WhatIf:($Dialog.CanWhatIf -and $Dialog.WhatIf.Checked))
}

# Check now: DNS + ports for the target fields (local) or WinRM for the remote list.
function Invoke-LibraryRunCheck {
    param($Dialog)
    $box = $Dialog.CheckBox
    $box.ForeColor = $Dialog.App.Theme.Text
    $lines = New-Object System.Collections.Generic.List[string]
    $Dialog.Form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        if ($Dialog.RbRemote.Checked) {
            $t = @(Split-LibraryList $Dialog.Targets.Text)
            if ($t.Count -eq 0) { $box.Text = 'Enter the computers first.'; return }
            $res = @(Test-LibraryHostPorts -Hosts $t -Ports 5985, 5986)
            foreach ($r in $res) { $lines.Add($(if ($r.Status -eq 'OK') { "OK    $($r.Text)" } else { "FAIL  $($r.Text)" })) }
            $bad = @($res | Where-Object { $_.Status -ne 'OK' }).Count
            $lines.Insert(0, "$(if ($bad -eq 0) { 'OK  ' } elseif ($bad -lt $res.Count) { 'PART' } else { 'FAIL' })  $($res.Count - $bad) of $($res.Count) answer on WinRM.")
        }
        else {
            $pl = Get-LibraryRunDialogPlan -Dialog $Dialog
            $hosts = @($pl.Hosts)
            $usable = @($pl.Plan | Where-Object { @($_.Ports).Count })
            if ($hosts.Count -eq 0 -or $usable.Count -eq 0) {
                $lines.Add($(if ($hosts.Count -eq 0) { 'No target computer in the fields - nothing to check (runs on this computer).' } else { 'This command has no port to check (it tests the connection itself, or works locally).' }))
            }
            else {
                $first = $true
                foreach ($m in $pl.Plan) {
                    if (@($m.Ports).Count -eq 0) { continue }
                    $res = @(Test-LibraryHostPorts -Hosts $hosts -Ports $m.Ports)
                    $ok = @($res | Where-Object { $_.Status -eq 'OK' }).Count
                    $lines.Add("$(if ($ok -eq $res.Count) { 'OK  ' } elseif ($ok) { 'PART' } else { 'FAIL' })  $($m.Label) needs TCP $(@($m.Ports) -join '/'):")
                    foreach ($r in $res) { $lines.Add("        $($r.Text)") }
                    if ($ok -eq $res.Count -and $first) { break }
                    $first = $false
                }
            }
        }
    }
    catch { $lines.Add("Check failed: $($_.Exception.Message)") }
    finally { $Dialog.Form.Cursor = [System.Windows.Forms.Cursors]::Default }
    $box.Text = ($lines -join "`r`n")
    $t = $box.Text
    $box.ForeColor = if ($t -match '(?m)^FAIL' -and $t -notmatch '(?m)^OK') { [System.Drawing.Color]::Firebrick }
        elseif ($t -match '(?m)^(FAIL|PART)') { [System.Drawing.Color]::FromArgb(150, 90, 0) }
        elseif ($t -match '(?m)^OK') { [System.Drawing.Color]::FromArgb(20, 100, 40) }
        else { $Dialog.App.Theme.Text }
}
