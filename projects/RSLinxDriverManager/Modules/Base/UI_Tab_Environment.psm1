# UI_Tab_Environment.psm1   (BASE TIER)
#
# The Environment tab.
#
#   Environment: [ saved environments  v ]  [New...] [Delete] [Save]   status
#   +---------------------------------------------------------------------+
#   | General | <project pages: Register-EnvironmentSection> ...          |
#   +---------------------------------------------------------------------+
#
#   Picker   every saved environment (Services_EnvironmentStore: the runtime
#            store over the embedded set). Picking one makes it active
#            (remembered per machine) and loads its values into every page.
#   New...   starts a new environment (optionally a copy of the current one).
#   Delete   removes the selected environment from this machine.
#   Save     writes the values of EVERY page to the selected environment.
#            Leaving an environment with unsaved changes asks first.
#
#   General  (template - every project):
#            the text fields in Config\EnvironmentFields.json (default:
#            Environment name, Log & data path, Variable 1-4);
#            Lists & logs (this environment): Filter as I type, action-log size;
#            Logging (all environments): Session.log size, diagnostics.
#   Project pages: one sub-tab per Register-EnvironmentSection (see
#            Services_Environment.psm1 for the Load / Collect / Validate contract).
#
# Editing: admin password and developer build ($App.CanEditDefaults). With the
# user password everything is read-only; the picker still works.

function New-EnvironmentTab {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.TabPage]$Page,
        [Parameter(Mandatory)] $App
    )
    Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction SilentlyContinue
    $Page.Padding = New-Object System.Windows.Forms.Padding(0)

    # All state and helpers live in $st so every closure sees the same objects.
    $st = @{
        App = $App; Editable = [bool]$App.CanEditDefaults; Busy = $false; Built = $false
        Names = @(); Pages = (New-Object System.Collections.ArrayList); Snapshot = ''
        Red = [System.Drawing.Color]::FromArgb(156, 0, 6); Green = [System.Drawing.Color]::FromArgb(0, 97, 0)
    }

    # ---------------- top bar ----------------
    $top = New-Object System.Windows.Forms.Panel
    $top.Dock = 'Top'; $top.Height = 46; $top.BackColor = $App.Theme.Panel

    $lblEnv = New-Object System.Windows.Forms.Label
    $lblEnv.Text = 'Environment:'; $lblEnv.Location = New-Object System.Drawing.Point(10, 14); $lblEnv.AutoSize = $true
    if (Get-Command Set-SectionStyle -ErrorAction SilentlyContinue) { Set-SectionStyle -App $App -Label $lblEnv }
    $top.Controls.Add($lblEnv)

    $combo = New-Object System.Windows.Forms.ComboBox
    $combo.DropDownStyle = 'DropDownList'; $combo.Location = New-Object System.Drawing.Point(110, 11); $combo.Width = 320
    $top.Controls.Add($combo); $st.Combo = $combo

    $x = 444
    foreach ($b in @(@{ K = 'BtnNew'; T = 'New...' }, @{ K = 'BtnDelete'; T = 'Delete' }, @{ K = 'BtnSave'; T = 'Save' })) {
        $btn = $App.Theme.MakeButton($b.T); $btn.AutoSize = $false; $btn.Size = New-Object System.Drawing.Size(84, 28)
        $btn.Location = New-Object System.Drawing.Point($x, 9); $x += 92
        $btn.Visible = $st.Editable
        $top.Controls.Add($btn); $st[$b.K] = $btn
    }
    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Location = New-Object System.Drawing.Point($(if ($st.Editable) { $x + 8 } else { 444 }), 15); $lblStatus.AutoSize = $true
    $lblStatus.ForeColor = $App.Theme.Muted
    $top.Controls.Add($lblStatus); $st.Status = $lblStatus

    $sub = New-Object System.Windows.Forms.TabControl
    $sub.Dock = 'Fill'
    $Page.Controls.Add($sub)          # Fill first, then the Top band (dock order)
    $Page.Controls.Add($top)
    $st.Sub = $sub

    # ---------------- General ----------------
    $tpGen = New-Object System.Windows.Forms.TabPage '  General  '
    $tpGen.AutoScroll = $true; $tpGen.BackColor = $App.Theme.Surface
    $sub.TabPages.Add($tpGen)
    $gen = @{}

    $addHeader = {
        param($Parent, [string]$Text, [int]$Y)
        $h = New-Object System.Windows.Forms.Label
        $h.Text = $Text; $h.Location = New-Object System.Drawing.Point(12, $Y); $h.AutoSize = $true
        if (Get-Command Set-SectionStyle -ErrorAction SilentlyContinue) { Set-SectionStyle -App $App -Label $h }
        $Parent.Controls.Add($h)
        $line = New-Object System.Windows.Forms.Panel
        $line.Location = New-Object System.Drawing.Point(12, ($Y + 22)); $line.Size = New-Object System.Drawing.Size(720, 1); $line.BackColor = $App.Theme.Border
        $Parent.Controls.Add($line)
    }
    $addHint = {
        param($Parent, [string]$Text, [int]$X, [int]$Y, [int]$W = 560, [int]$H = 30)
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $Text; $l.Location = New-Object System.Drawing.Point($X, $Y); $l.Size = New-Object System.Drawing.Size($W, $H); $l.ForeColor = $App.Theme.Muted
        $Parent.Controls.Add($l)
    }
    $addText = {
        param($Parent, [string]$Caption, [int]$Y, [int]$W = 440)
        $lab = New-Object System.Windows.Forms.Label
        $lab.Text = $Caption + ':'; $lab.Location = New-Object System.Drawing.Point(12, ($Y + 3)); $lab.AutoSize = $true
        $box = New-Object System.Windows.Forms.TextBox
        $box.Location = New-Object System.Drawing.Point(240, $Y); $box.Width = $W
        $Parent.Controls.Add($lab); $Parent.Controls.Add($box)
        return $box
    }

    $note = New-Object System.Windows.Forms.Label
    $note.Location = New-Object System.Drawing.Point(12, 10); $note.Size = New-Object System.Drawing.Size(900, 30); $note.ForeColor = $App.Theme.Muted
    $note.Text = if (-not $st.Editable) { 'Read-only. Environments are created and edited with the admin password.' }
                 elseif ([string]$App.Tier -eq 'Developer') { 'Values for the environment selected above, on every page. Save keeps them on this machine (Settings\Environments.json) and stages them in Config\Environments.json for the next build.' }
                 else { 'Values for the environment selected above, on every page. Save keeps them on this machine (Settings\Environments.json).' }
    $tpGen.Controls.Add($note)

    $y = 46
    & $addHeader $tpGen 'Environment' $y; $y += 32
    $fields = if (Get-Command Get-EnvironmentFieldList -ErrorAction SilentlyContinue) { @(Get-EnvironmentFieldList -App $App) }
              else { @([pscustomobject]@{ Key = 'Label'; Caption = 'Environment name' }, [pscustomobject]@{ Key = 'SharedPath'; Caption = 'Log & data path (UNC, optional)' }) }
    $gen.Text = [ordered]@{}
    foreach ($f in $fields) { $gen.Text[$f.Key] = & $addText $tpGen $f.Caption $y; $y += 30 }
    $gen.Root = New-Object System.Windows.Forms.Label
    $gen.Root.Location = New-Object System.Drawing.Point(240, ($y + 2)); $gen.Root.AutoSize = $true; $gen.Root.ForeColor = $App.Theme.Muted
    $tpGen.Controls.Add($gen.Root); $y += 30

    $y += 8
    & $addHeader $tpGen 'Lists & logs  (this environment)' $y; $y += 32
    $gen.Filter = New-Object System.Windows.Forms.CheckBox
    $gen.Filter.Text = 'Filter as I type'; $gen.Filter.Location = New-Object System.Drawing.Point(240, $y); $gen.Filter.AutoSize = $true
    $tpGen.Controls.Add($gen.Filter); $y += 24
    & $addHint $tpGen 'Default for list filters: re-filter on every keystroke. Turn off where lists are large - they then filter on Enter.' 240 $y 600 18; $y += 26
    $gen.LogMax = & $addText $tpGen 'Action log max (KB)' $y 120; $y += 28
    & $addHint $tpGen 'Size limit of this environment''s action log (Logs\<name>.log). When full, the oldest entries are removed. Minimum 64.' 240 $y 600 18; $y += 30

    $y += 8
    & $addHeader $tpGen 'Logging  (all environments)' $y; $y += 32
    $gen.SessMax = & $addText $tpGen 'Session log max (KB)' $y 120; $y += 30
    $gen.Diag = New-Object System.Windows.Forms.CheckBox
    $gen.Diag.Text = 'Diagnostic / troubleshooting logging'; $gen.Diag.Location = New-Object System.Drawing.Point(240, $y); $gen.Diag.AutoSize = $true
    $tpGen.Controls.Add($gen.Diag); $y += 24
    & $addHint $tpGen 'Session.log holds status and session messages for every environment; when full the oldest lines are removed. Diagnostic logging adds troubleshooting detail - leave it off unless investigating. Errors and warnings are always logged.' 240 $y 600 32

    $genApi = @{
        Load = {
            param($Record)
            foreach ($k in @($gen.Text.Keys)) { $gen.Text[$k].Text = $(if ($Record.Contains($k)) { [string]$Record[$k] } else { '' }) }
            $gen.Filter.Checked = $(if ($Record.Contains('FilterAsYouType') -and $null -ne $Record['FilterAsYouType'] -and [string]$Record['FilterAsYouType'] -ne '') { [bool]$Record['FilterAsYouType'] } else { $true })
            $gen.LogMax.Text = $(if ($Record.Contains('LogMaxKB') -and [string]$Record['LogMaxKB']) { [string]$Record['LogMaxKB'] } else { '5120' })
            if (Get-Command Get-AppLoggingSettings -ErrorAction SilentlyContinue) {
                $ls = Get-AppLoggingSettings -App $App
                $gen.SessMax.Text = [string]$ls.SessionLogMaxKB; $gen.Diag.Checked = [bool]$ls.DiagnosticsEnabled
            }
            $gen.Root.Text = switch ([string]$App.DataRootStatus) {
                'Network'       { 'Logs and data are on the shared path.' }
                'LocalFallback' { 'Shared path set but not reachable - logs and data are in local AppData.' }
                default         { 'No shared path - logs and data are in local AppData.' }
            }
        }.GetNewClosure()
        Collect = {
            param($Record)
            $h = [ordered]@{}
            foreach ($k in @($gen.Text.Keys)) { $h[$k] = $gen.Text[$k].Text.Trim() }
            $h['FilterAsYouType'] = [bool]$gen.Filter.Checked
            $n = 0; if ([int]::TryParse($gen.LogMax.Text.Trim(), [ref]$n)) { $h['LogMaxKB'] = $n } else { $h['LogMaxKB'] = $gen.LogMax.Text.Trim() }
            $s = 0; [void][int]::TryParse($gen.SessMax.Text.Trim(), [ref]$s)
            $h['__SessionLogMaxKB'] = $s; $h['__Diagnostics'] = [bool]$gen.Diag.Checked     # app-wide, saved separately
            return $h
        }.GetNewClosure()
        Validate = {
            param($Record)
            if ($gen.Text.Contains('Label') -and -not $gen.Text['Label'].Text.Trim()) { return 'The environment needs a name.' }
            $n = 0
            if (-not [int]::TryParse($gen.LogMax.Text.Trim(), [ref]$n) -or $n -lt 64) { return 'Action log max must be a whole number of KB, 64 or more.' }
            if (-not [int]::TryParse($gen.SessMax.Text.Trim(), [ref]$n) -or $n -lt 64) { return 'Session log max must be a whole number of KB, 64 or more.' }
            return ''
        }.GetNewClosure()
    }
    [void]$st.Pages.Add(@{ Title = 'General'; Page = $tpGen; Api = $genApi })

    # ---------------- helpers ----------------
    $st.SetStatus = {
        param([string]$Text, [string]$Kind = '')
        $st.Status.Text = $Text
        $st.Status.ForeColor = switch ($Kind) { 'err' { $st.Red } 'ok' { $st.Green } default { $st.App.Theme.Muted } }
    }.GetNewClosure()

    $st.Format = {
        param($v)
        if ($null -eq $v) { return '' }
        if ($v -is [string] -or $v -is [bool] -or $v -is [int] -or $v -is [long] -or $v -is [double]) { return [string]$v }
        try { return (ConvertTo-Json -InputObject $v -Depth 10 -Compress) } catch { return [string]$v }
    }.GetNewClosure()

    # Everything the pages would save right now, as one string (for "unsaved changes?").
    $st.Fingerprint = {
        $rec = $st.Record
        $sb = New-Object System.Text.StringBuilder
        foreach ($pg in $st.Pages) {
            if (-not $pg.Api) { continue }
            if ($pg.Api.Fingerprint) {         # page-defined (e.g. rich text that a browser re-serializes)
                try { [void]$sb.Append($pg.Title).Append(':').Append([string](& $pg.Api.Fingerprint $rec)).Append("`n") } catch { }
                continue
            }
            if (-not $pg.Api.Collect) { continue }
            try {
                $vals = & $pg.Api.Collect $rec
                foreach ($k in @($vals.Keys)) { [void]$sb.Append($k).Append('=').Append((& $st.Format $vals[$k])).Append("`n") }
            } catch { }
        }
        return $sb.ToString()
    }.GetNewClosure()

    $st.IsDirty = { return ($st.Editable -and $st.Built -and (& $st.Fingerprint) -ne $st.Snapshot) }.GetNewClosure()

    $st.FillCombo = {
        $st.Busy = $true
        try {
            $st.Combo.Items.Clear()
            $st.Names = @($st.App.EnvironmentNames())
            foreach ($l in $st.App.EnvironmentLabels()) { [void]$st.Combo.Items.Add($l) }
            if ($st.Combo.Items.Count -gt 0) { $st.Combo.SelectedIndex = [Math]::Min([int]$st.App.ActiveEnvironmentIndex(), $st.Combo.Items.Count - 1) }
            if ($st.BtnDelete) { $st.BtnDelete.Enabled = ($st.Combo.Items.Count -gt 1) }
        }
        finally { $st.Busy = $false }
    }.GetNewClosure()

    $st.LoadAll = {
        $rec = $null
        if (Get-Command Get-AppEnvironmentRecord -ErrorAction SilentlyContinue) { $rec = Get-AppEnvironmentRecord -App $st.App }
        if (-not $rec) { $rec = [ordered]@{ Name = [string]$st.App.ActiveName; Label = [string]$st.App.ActiveLabel } }
        $st.Record = $rec
        foreach ($pg in $st.Pages) {
            if (-not $pg.Api -or -not $pg.Api.Load) { continue }
            try { & $pg.Api.Load $rec }
            catch { $st.App.Log('ERROR', 'Environment', "$($pg.Title) page: loading '$($rec['Name'])' failed: $($_.Exception.ToString())") }
        }
        $st.Snapshot = & $st.Fingerprint
    }.GetNewClosure()

    # Save every page into the active environment. Returns $true on success.
    $st.Save = {
        foreach ($pg in $st.Pages) {
            if (-not $pg.Api -or -not $pg.Api.Validate) { continue }
            $msg = ''
            try { $msg = [string](& $pg.Api.Validate $st.Record) } catch { $msg = $_.Exception.Message }
            if ($msg) {
                $st.Sub.SelectedTab = $pg.Page
                & $st.SetStatus "Not saved - $($pg.Title): $msg" 'err'
                [System.Windows.Forms.MessageBox]::Show("$($pg.Title): $msg", 'Environment', 'OK', 'Warning') | Out-Null
                return $false
            }
        }
        $rec = ConvertTo-EnvRecord $st.Record
        $before = '{0}|{1}|{2}' -f $rec['SharedPath'], $rec['Domain'], $rec['Server']
        $sess = 0; $diag = $false
        foreach ($pg in $st.Pages) {
            if (-not $pg.Api -or -not $pg.Api.Collect) { continue }
            $vals = & $pg.Api.Collect $st.Record
            foreach ($k in @($vals.Keys)) {
                if ($k -eq '__SessionLogMaxKB') { $sess = [int]$vals[$k]; continue }
                if ($k -eq '__Diagnostics')     { $diag = [bool]$vals[$k]; continue }
                $rec[$k] = $vals[$k]
            }
        }
        try {
            $saved = Save-AppEnvironmentRecord -App $st.App -Record $rec
            if ($sess -ge 64 -and (Get-Command Set-AppLoggingSettings -ErrorAction SilentlyContinue)) { Set-AppLoggingSettings -App $st.App -DiagnosticsEnabled $diag -SessionLogMaxKB $sess }
        }
        catch {
            $st.App.Log('ERROR', 'Environment', "save failed: $($_.Exception.ToString())")
            & $st.SetStatus "Save failed: $($_.Exception.Message)" 'err'
            return $false
        }
        $st.Record = $saved
        & $st.FillCombo
        $after = '{0}|{1}|{2}' -f $saved['SharedPath'], $saved['Domain'], $saved['Server']
        if ($after -ne $before -and (Get-Command Invoke-EnvironmentChanged -ErrorAction SilentlyContinue)) { Invoke-EnvironmentChanged -App $st.App }
        if (Get-Command Invoke-AppSettingsChanged -ErrorAction SilentlyContinue) { Invoke-AppSettingsChanged -App $st.App -Name 'Environment' }
        $st.App.Log('INFO', 'Environment', "Saved environment '$($saved['Name'])'.")
        $st.Snapshot = & $st.Fingerprint
        & $st.SetStatus "Saved $((Get-Date).ToString('HH:mm:ss'))." 'ok'
        return $true
    }.GetNewClosure()

    # Unsaved changes? Ask. Returns $false when the user cancels.
    $st.ConfirmLeave = {
        if (-not (& $st.IsDirty)) { return $true }
        $r = [System.Windows.Forms.MessageBox]::Show(
            "Save the changes to '$($st.Record['Label'])' first?", 'Environment',
            [System.Windows.Forms.MessageBoxButtons]::YesNoCancel, [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($r -eq [System.Windows.Forms.DialogResult]::Cancel) { return $false }
        if ($r -eq [System.Windows.Forms.DialogResult]::Yes)    { return [bool](& $st.Save) }
        return $true
    }.GetNewClosure()

    $st.Activate = {
        param([string]$Name)
        $frm = $st.Combo.FindForm(); if ($frm) { $frm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor }
        try {
            [void]$st.App.SelectEnvironment($Name)
            if (Get-Command Invoke-EnvironmentChanged -ErrorAction SilentlyContinue) { Invoke-EnvironmentChanged -App $st.App }
            & $st.FillCombo
            if ($st.Built) { & $st.LoadAll }
            & $st.SetStatus ''
        }
        finally { if ($frm) { $frm.Cursor = [System.Windows.Forms.Cursors]::Default } }
    }.GetNewClosure()

    # ---------------- events ----------------
    $combo.Add_SelectedIndexChanged({
        if ($st.Busy) { return }
        $i = $st.Combo.SelectedIndex
        if ($i -lt 0 -or $i -ge $st.Names.Count) { return }
        $name = [string]$st.Names[$i]
        if ($name -eq [string]$st.App.ActiveName) { return }
        if (-not (& $st.ConfirmLeave)) { & $st.FillCombo; return }    # cancelled: back to the active one
        & $st.Activate $name
    }.GetNewClosure())

    $st.BtnSave.Add_Click({ [void](& $st.Save) }.GetNewClosure())

    $st.BtnNew.Add_Click({
        if (-not (& $st.ConfirmLeave)) { return }
        $label = [Microsoft.VisualBasic.Interaction]::InputBox('Name for the new environment:', 'New environment', '')
        if (-not $label -or -not $label.Trim()) { return }
        $copy = $null
        $cur = [string]$st.Record['Label']
        $r = [System.Windows.Forms.MessageBox]::Show(
            "Start from a copy of '$cur'?`r`n`r`nYes = copy its settings (not its domain / server).`r`nNo = start blank.",
            'New environment', [System.Windows.Forms.MessageBoxButtons]::YesNoCancel, [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($r -eq [System.Windows.Forms.DialogResult]::Cancel) { return }
        if ($r -eq [System.Windows.Forms.DialogResult]::Yes) { $copy = $st.Record }
        try {
            $new = New-AppEnvironmentRecord -App $st.App -Label $label.Trim() -CopyFrom $copy -Exclude @('Domain', 'Server')
            & $st.Activate ([string]$new['Name'])
            $st.Sub.SelectedTab = $st.Pages[0].Page
            & $st.SetStatus "Created '$($new['Label'])' - fill in its pages and Save." 'ok'
        }
        catch { & $st.SetStatus "Could not create it: $($_.Exception.Message)" 'err' }
    }.GetNewClosure())

    $st.BtnDelete.Add_Click({
        $label = [string]$st.Record['Label']; $name = [string]$st.Record['Name']
        $r = [System.Windows.Forms.MessageBox]::Show(
            "Delete the environment '$label' and all of its settings from this machine?", 'Delete environment',
            [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        try {
            Remove-AppEnvironmentRecord -App $st.App -Name $name
            $st.Snapshot = & $st.Fingerprint                 # nothing left to save for the deleted one
            & $st.Activate ([string]$st.App.ActiveName)
            & $st.SetStatus "Deleted '$label'." 'ok'
        }
        catch { & $st.SetStatus "Could not delete it: $($_.Exception.Message)" 'err' }
    }.GetNewClosure())

    # ---------------- build on first view ----------------
    $st.Build = {
        $frm = $st.Combo.FindForm(); if ($frm) { $frm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor }
        try {
            $sections = if (Get-Command Get-EnvironmentSections -ErrorAction SilentlyContinue) { @(Get-EnvironmentSections) } else { @() }
            foreach ($s in $sections) {
                $tp = New-Object System.Windows.Forms.TabPage ('  ' + $(if ($s.Title) { $s.Title } else { 'Settings' }) + '  ')
                $tp.AutoScroll = $true; $tp.BackColor = $st.App.Theme.Surface
                $st.Sub.TabPages.Add($tp)
                $api = $null
                try {
                    $out = @(& $s.Build $tp $st.App)
                    $api = @($out | Where-Object { $_ -is [hashtable] -and ($_.ContainsKey('Load') -or $_.ContainsKey('Collect')) }) | Select-Object -Last 1
                }
                catch {
                    $st.App.Log('ERROR', 'Environment', "page '$($s.Title)' failed to build: $($_.Exception.ToString())")
                    $err = New-Object System.Windows.Forms.Label
                    $err.Text = "This page failed to build: $($_.Exception.Message)`r`nDetails are in Session.log."
                    $err.Location = New-Object System.Drawing.Point(12, 12); $err.AutoSize = $true; $err.ForeColor = [System.Drawing.Color]::Firebrick
                    $tp.Controls.Add($err)
                }
                [void]$st.Pages.Add(@{ Title = [string]$s.Title; Page = $tp; Api = $api })
            }
            $st.App.Log('INFO', 'Environment', "Environment tab built: General + $($sections.Count) page(s).")
            if (-not $st.Editable) {
                foreach ($pg in $st.Pages) {
                    try { Set-EnvironmentControlsReadOnly -Control $pg.Page }
                    catch { $st.App.Log('WARN', 'Environment', "read-only view of '$($pg.Title)': $($_.Exception.Message)") }
                }
            }
            $st.Built = $true
            & $st.FillCombo
            & $st.LoadAll
        }
        catch { $st.App.Log('ERROR', 'Environment', "building the Environment tab failed: $($_.Exception.ToString())") }
        finally { if ($frm) { $frm.Cursor = [System.Windows.Forms.Cursors]::Default } }
    }.GetNewClosure()

    & $st.FillCombo
    $Page.Tag = @{ OnActivate = $st.Build; NoReplay = $true }
}

# Read-only view: text boxes read-only, other inputs disabled; anything that
# holds other controls (panels, tab pages, group boxes ...) is walked instead.
function Set-EnvironmentControlsReadOnly {
    param([System.Windows.Forms.Control]$Control)
    foreach ($c in $Control.Controls) {
        if ($c -is [System.Windows.Forms.TextBoxBase]) { $c.ReadOnly = $true; continue }
        if ($c -is [System.Windows.Forms.Label]) { continue }
        if ($c.Controls.Count -gt 0 -and -not ($c -is [System.Windows.Forms.ComboBox])) { Set-EnvironmentControlsReadOnly -Control $c; continue }
        $c.Enabled = $false
    }
}
