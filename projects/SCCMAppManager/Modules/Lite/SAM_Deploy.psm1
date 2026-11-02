# SAM_Deploy.psm1   (LITE TIER)
#
# Deploy dialog (ported from v8.4): 1) pick a collection (all collections shown,
# filter as you type)  2) Required / Available, now or a set time, optional
# content distribution to the environment's DP group.

function Show-SamDeployDialog {
    param($AppNames, [string]$PreselectCollectionID = '')
    $S = $global:SAM
    $bold = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Deploy Application  -  site $($S.Settings.SiteCode)"
    $dlg.Size = New-Object System.Drawing.Size(820, 780)
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.ShowInTaskbar = $false

    $names = @($AppNames)
    $shown = @($names | Select-Object -First 4)
    $appText = $shown -join ', '
    if ($names.Count -gt $shown.Count) { $appText += " ... (+$($names.Count - $shown.Count) more)" }
    $lblApps = New-Object System.Windows.Forms.Label
    $lblApps.Location = New-Object System.Drawing.Point(12, 10); $lblApps.Size = New-Object System.Drawing.Size(780, 36)
    $lblApps.Text = "Deploying $($names.Count) application(s): $appText"
    $dlg.Controls.Add($lblApps)

    # ---- 1. Collection ----
    $l1 = New-Object System.Windows.Forms.Label
    $l1.Text = '1. Collection'; $l1.Font = $bold; $l1.Location = New-Object System.Drawing.Point(12, 52); $l1.AutoSize = $true
    $dlg.Controls.Add($l1)
    $lf = New-Object System.Windows.Forms.Label
    $lf.Text = 'Filter:'; $lf.Location = New-Object System.Drawing.Point(120, 53); $lf.AutoSize = $true
    $dlg.Controls.Add($lf)
    $txtF = New-Object System.Windows.Forms.TextBox
    $txtF.Location = New-Object System.Drawing.Point(165, 50); $txtF.Width = 300
    $dlg.Controls.Add($txtF)
    $lblN = New-Object System.Windows.Forms.Label
    $lblN.Location = New-Object System.Drawing.Point(480, 53); $lblN.AutoSize = $true
    $dlg.Controls.Add($lblN)

    $g = New-SamDataGrid -Key 'ID' -Columns @(
        @{ Name = 'Name'; Header = 'Collection'; Fill = 60 },
        @{ Name = 'ID'; Width = 90 },
        @{ Name = 'Members'; Type = 'int'; Width = 75 },
        @{ Name = 'AppDeploys'; Header = 'App deploys'; Type = 'int'; Width = 85 },
        @{ Name = 'Type'; Width = 60 })
    $g.Grid.Location = New-Object System.Drawing.Point(12, 80); $g.Grid.Size = New-Object System.Drawing.Size(780, 300)
    $dlg.Controls.Add($g.Grid)
    Set-SamGridData -G $g -Items $S.Cache.Collections.ToArray()
    Set-SamGridFilter -G $g -Text '' -CountLabel $lblN

    # ---- 2. Purpose and schedule ----
    $l2 = New-Object System.Windows.Forms.Label
    $l2.Text = '2. Purpose and schedule'; $l2.Font = $bold; $l2.Location = New-Object System.Drawing.Point(12, 395); $l2.AutoSize = $true
    $dlg.Controls.Add($l2)

    $rbReq = New-Object System.Windows.Forms.RadioButton
    $rbReq.Text = 'Required'; $rbReq.Checked = $true; $rbReq.Location = New-Object System.Drawing.Point(30, 420); $rbReq.AutoSize = $true
    $rbAvl = New-Object System.Windows.Forms.RadioButton
    $rbAvl.Text = 'Available'; $rbAvl.Location = New-Object System.Drawing.Point(140, 420); $rbAvl.AutoSize = $true
    $dlg.Controls.Add($rbReq); $dlg.Controls.Add($rbAvl)

    $mkTime = {
        param($label, $nowText, $y)
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $label; $l.Location = New-Object System.Drawing.Point(30, ($y + 3)); $l.Size = New-Object System.Drawing.Size(130, 20)
        $chk = New-Object System.Windows.Forms.CheckBox
        $chk.Text = $nowText; $chk.Checked = $true; $chk.Location = New-Object System.Drawing.Point(165, $y); $chk.Size = New-Object System.Drawing.Size(200, 24)
        $dt = New-Object System.Windows.Forms.DateTimePicker
        $dt.Format = 'Custom'; $dt.CustomFormat = 'ddd yyyy-MM-dd  HH:mm'; $dt.ShowUpDown = $false
        $dt.Location = New-Object System.Drawing.Point(370, $y); $dt.Width = 220; $dt.Enabled = $false
        $dt.Value = (Get-Date).AddMinutes(30 - ((Get-Date).Minute % 30)).AddSeconds(-(Get-Date).Second)
        $chk.Add_CheckedChanged({ $dt.Enabled = -not $chk.Checked }.GetNewClosure())
        $dlg.Controls.Add($l); $dlg.Controls.Add($chk); $dlg.Controls.Add($dt)
        return @{ Label = $l; Now = $chk; Picker = $dt }
    }
    $tAvail = & $mkTime 'Available from:' 'Now' 452
    $tDead  = & $mkTime 'Deadline:' 'As soon as possible' 484

    $lTb = New-Object System.Windows.Forms.Label
    $lTb.Text = 'Times are:'; $lTb.Location = New-Object System.Drawing.Point(30, 519); $lTb.AutoSize = $true
    $cboTb = New-Object System.Windows.Forms.ComboBox
    $cboTb.DropDownStyle = 'DropDownList'; $cboTb.Location = New-Object System.Drawing.Point(165, 516); $cboTb.Width = 200
    [void]$cboTb.Items.Add('Client local time'); [void]$cboTb.Items.Add('UTC'); $cboTb.SelectedIndex = 0
    $dlg.Controls.Add($lTb); $dlg.Controls.Add($cboTb)

    $chkDist = New-Object System.Windows.Forms.CheckBox
    $dpg = [string]$S.Settings.DPGroup
    $chkDist.Text = if ($dpg) { "Distribute content to DP group '$dpg' first" } else { 'Distribute content first (no DP group set for this environment)' }
    $chkDist.Checked = [bool]$dpg; $chkDist.Enabled = [bool]$dpg
    $chkDist.Location = New-Object System.Drawing.Point(30, 550); $chkDist.AutoSize = $true
    $dlg.Controls.Add($chkDist)

    $note = New-Object System.Windows.Forms.Label
    $note.Location = New-Object System.Drawing.Point(30, 580); $note.Size = New-Object System.Drawing.Size(760, 70)
    $note.ForeColor = [System.Drawing.Color]::DimGray
    $dlg.Controls.Add($note)

    $syncPurpose = {
        $req = $rbReq.Checked
        $tDead.Label.Enabled = $req; $tDead.Now.Enabled = $req
        $tDead.Picker.Enabled = $req -and -not $tDead.Now.Checked
        $note.Text = if ($req) {
            'Required: installs automatically at the deadline. Installs outside maintenance windows, no reboot outside maintenance windows, Software Center notifications only, wake-up packets sent, user repair enabled.'
        } else {
            'Available: users install it from Software Center when they choose. Notifications shown, no deadline, user repair enabled.'
        }
    }.GetNewClosure()
    $rbReq.Add_CheckedChanged($syncPurpose)
    $tDead.Now.Add_CheckedChanged($syncPurpose)
    & $syncPurpose

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = 'Deploy'; $btnOk.Size = New-Object System.Drawing.Size(130, 34); $btnOk.Location = New-Object System.Drawing.Point(522, 688)
    $btnOk.BackColor = [System.Drawing.Color]::LightGreen; $btnOk.Font = $bold
    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = 'Cancel'; $btnCancel.Size = New-Object System.Drawing.Size(130, 34); $btnCancel.Location = New-Object System.Drawing.Point(662, 688)
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dlg.Controls.Add($btnOk); $dlg.Controls.Add($btnCancel)
    $dlg.CancelButton = $btnCancel

    $res = @{ Value = $null }
    $btnOk.Add_Click({
        $sel = @(Get-SamGridSelected -G $g)
        if (-not $sel.Count) {
            [void][System.Windows.Forms.MessageBox]::Show($dlg, 'Pick a collection.', 'Deploy', 'OK', 'Warning'); return
        }
        $now = Get-Date
        $avail = if ($tAvail.Now.Checked) { $now } else { $tAvail.Picker.Value }
        $dead  = $null
        if ($rbReq.Checked) {
            $dead = if ($tDead.Now.Checked) { $(if ($avail -gt $now) { $avail } else { $now }) } else { $tDead.Picker.Value }
            if ($dead -lt $avail) {
                [void][System.Windows.Forms.MessageBox]::Show($dlg, 'The deadline is earlier than the available time.', 'Deploy', 'OK', 'Warning'); return
            }
        }
        $c = $sel[0]
        $res.Value = [pscustomobject]@{
            CollectionName = $c.Name
            CollectionID   = $c.ID
            CollectionType = $c.Type
            Purpose        = $(if ($rbReq.Checked) { 'Required' } else { 'Available' })
            AvailableTime  = $avail
            AvailableNow   = $tAvail.Now.Checked
            DeadlineTime   = $dead
            DeadlineNow    = ($rbReq.Checked -and $tDead.Now.Checked)
            TimeBase       = $(if ($cboTb.SelectedIndex -eq 1) { 'Utc' } else { 'LocalTime' })
            Distribute     = $chkDist.Checked
        }
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK
    }.GetNewClosure())

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 200
    $timer.Add_Tick({ $timer.Stop(); Set-SamGridFilter -G $g -Text $txtF.Text -CountLabel $lblN }.GetNewClosure())
    $txtF.Add_TextChanged({ $timer.Stop(); $timer.Start() }.GetNewClosure())

    $pre = if ($PreselectCollectionID) { $PreselectCollectionID } else {
        $tc = $S.Cache.CollectionsByName[[string]$S.Settings.TestCollection]
        if ($tc) { $tc.ID } else { '' }
    }
    $dlg.Add_Shown({ if ($pre) { Select-SamGridRowsBy -G $g -Property 'ID' -Values @($pre) } else { $g.Grid.ClearSelection() } }.GetNewClosure())

    try {
        if ($dlg.ShowDialog((Get-SamOwnerForm)) -eq [System.Windows.Forms.DialogResult]::OK) { return $res.Value }
        return $null
    }
    finally { $timer.Dispose(); $dlg.Dispose() }
}

function Format-SamDeploySummary {
    param($Opt)
    $when = if ($Opt.AvailableNow) { 'now' } else { $Opt.AvailableTime.ToString('yyyy-MM-dd HH:mm') }
    $s = "$($Opt.Purpose) to '$($Opt.CollectionName)', available $when"
    if ($Opt.Purpose -eq 'Required') {
        $s += ', deadline ' + $(if ($Opt.DeadlineNow) { 'ASAP' } else { $Opt.DeadlineTime.ToString('yyyy-MM-dd HH:mm') })
    }
    if ($Opt.TimeBase -eq 'Utc') { $s += ' (UTC)' }
    return $s
}

function Invoke-SamDeployApp {
    param([string]$AppName, $Opt)
    $S = $global:SAM
    $ok = Invoke-SamCM {
        if ($Opt.Distribute -and $S.Settings.DPGroup) {
            try {
                Start-CMContentDistribution -ApplicationName $AppName -DistributionPointGroupName $S.Settings.DPGroup -ErrorAction Stop | Out-Null
                Write-SamLog "  Content distribution started to $($S.Settings.DPGroup)" -Level Success
            }
            catch { Write-SamLog "  Content distribution: $($_.Exception.Message)" -Level Warning }
        }

        $dp = @{
            Name                       = $AppName
            CollectionName             = $Opt.CollectionName
            DeployAction               = 'Install'
            DeployPurpose              = $Opt.Purpose
            AvailableDateTime          = $Opt.AvailableTime
            TimeBaseOn                 = $Opt.TimeBase
            PersistOnWriteFilterDevice = $false
            EnableMomAlert             = $false
            RaiseMomAlertsOnFailure    = $false
            UseMeteredNetwork          = $false
        }
        if ($Opt.Purpose -eq 'Required') {
            $dp['DeadlineDateTime']           = $Opt.DeadlineTime
            $dp['UserNotification']           = 'DisplaySoftwareCenterOnly'
            $dp['OverrideServiceWindow']      = $true
            $dp['RebootOutsideServiceWindow'] = $false
            $dp['SendWakeupPacket']           = $true
        }
        else {
            $dp['UserNotification'] = 'DisplayAll'
        }
        try { $null = New-CMApplicationDeployment @dp -ErrorAction Stop; Write-SamLog "  Deployment created ($($Opt.Purpose))" -Level Success }
        catch { Write-SamLog "  New-CMApplicationDeployment failed: $($_.Exception.Message)" -Level Error; return $false }

        try {
            $null = Set-CMApplicationDeployment -ApplicationName $AppName -CollectionName $Opt.CollectionName -EnableRepair $true -ErrorAction Stop
            Write-SamLog '  Repair option enabled' -Level Success
        }
        catch { Write-SamLog "  Could not enable repair: $($_.Exception.Message)" -Level Warning }
        return $true
    }
    if (-not (@($ok) -contains $true)) { return $false }

    if ($Opt.Purpose -eq 'Required') {
        try {
            $q = 'SELECT * FROM SMS_ApplicationAssignment WHERE ApplicationName = {0} AND CollectionName = {1}' -f (ConvertTo-SamWql $AppName), (ConvertTo-SamWql $Opt.CollectionName)
            $a = Get-SamSmsData $q | Select-Object -First 1
            if ($a) { Set-CimInstance -InputObject $a -Property @{ OverrideServiceWindows = $true; RebootOutsideOfServiceWindows = $false } -ErrorAction Stop }
        }
        catch { Write-SamLog "  Could not apply maintenance-window settings: $($_.Exception.Message)" -Level Warning }
    }
    try { $S.App.LogAction("Deployed '$AppName': $(Format-SamDeploySummary $Opt)") } catch { }
    return $true
}

# Deploys applications (by name). -CollectionID preselects the collection.
function Invoke-SamDeployApps {
    param($AppNames, [string]$CollectionID = '')
    $S = $global:SAM
    $names = New-Object System.Collections.ArrayList
    foreach ($n in @($AppNames)) { if ($n) { [void]$names.Add([string]$n) } }
    if (-not $names.Count) { Write-SamLog 'Nothing to deploy - select one or more applications that exist in SCCM.' -Level Warning; return }
    if (-not $S.Cache.Collections.Count) { Write-SamLog 'No collections loaded - click Refresh.' -Level Error; return }

    $opt = Show-SamDeployDialog -AppNames $names.ToArray() -PreselectCollectionID $CollectionID
    if (-not $opt) { Write-SamLog 'Deploy cancelled.'; return }
    Write-SamLog ('Deploy options: ' + (Format-SamDeploySummary $opt))

    $todo = New-Object System.Collections.ArrayList
    foreach ($n in $names) {
        $d = $S.Cache.DeployedTo[$n]
        if ($d -and $d[$opt.CollectionName]) { Write-SamLog "  $n is already deployed to '$($opt.CollectionName)' - skipping" -Level Warning }
        else { [void]$todo.Add($n) }
    }
    if (-not $todo.Count) { return }

    $check = foreach ($n in $todo) {
        $a = $S.Cache.AppsByName[$n]
        if ($a) { [pscustomobject]@{ Key = $n; Base = $a.BaseName; Version = $(if ($a.NameVersion) { $a.NameVersion } else { $a.Version }) } }
        else    { [pscustomobject]@{ Key = $n; Base = $null; Version = $null } }
    }
    $allowed = @(Confirm-SamNoNewerVersion -Items @($check) -Action 'deploy')
    $final = @($todo.ToArray() | Where-Object { $allowed -contains $_ })
    if (-not $final.Count) { return }

    $i = 0; $ok = 0
    foreach ($n in $final) {
        $i++; Set-SamProgress $i $final.Count 'Deploy'
        Write-SamLog "[$n] Deploying: $(Format-SamDeploySummary $opt)"
        if (@(Measure-SamStep "Deploy: $n -> $($opt.CollectionName)" { Invoke-SamDeployApp -AppName $n -Opt $opt }) -contains $true) { $ok++ }
    }
    Write-SamLog "Deploy finished: $ok of $($final.Count) succeeded" -Level Success
    Invoke-SamAfterSccmChange
}
