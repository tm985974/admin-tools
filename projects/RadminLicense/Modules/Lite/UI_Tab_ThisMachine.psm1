# UI_Tab_ThisMachine.psm1   (LITE TIER)
#
# This Machine tab: the whole round trip for the PC the app is running on -
# for a device that cannot be reached over the network (no WinRM), or when
# licensing one machine by hand. Same core as the Fleet tab (Services_Radmin).
#   1. Save request   -> C:\FAS\<NAME>.request  and  <Transfer>\Requests\<NAME>.request
#   2. (website, on an internet PC)
#   3. Apply license  <- <Transfer>\Licenses\<NAME>.license  (or browse for it)

function New-ThisMachineTab {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.TabPage]$Page,
        [Parameter(Mandatory)] $App
    )
    Set-LazyTabBuild -Page $Page -App $App -Build ${function:Build-ThisMachineTab}
}

function Build-ThisMachineTab {
    param($Page, $App)

    $R = Get-RadminApi
    $st = @{
        App = $App; R = $R; Me = [string]$env:COMPUTERNAME
        Green = [System.Drawing.Color]::FromArgb(24, 128, 56)
        Amber = [System.Drawing.Color]::FromArgb(176, 96, 0)
        Red   = [System.Drawing.Color]::Firebrick
    }
    $font  = { param([single]$size, [string]$style = 'Regular') New-Object System.Drawing.Font($App.Theme.FontName, $size, [System.Drawing.FontStyle]$style) }
    $label = {
        param([string]$text, [int]$x, [int]$y, [int]$w = 0)
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $text; $l.Location = New-Object System.Drawing.Point($x, $y)
        if ($w -gt 0) { $l.AutoSize = $true; $l.MaximumSize = New-Object System.Drawing.Size($w, 0) } else { $l.AutoSize = $true }
        $l.ForeColor = $App.Theme.Text
        return $l
    }

    $top = New-Object System.Windows.Forms.Panel
    $top.Dock = 'Top'; $top.Height = 470; $top.AutoScroll = $true

    $hdr = & $label ("This machine - " + $st.Me) 10 8
    Set-HeaderStyle -App $App -Label $hdr

    # ---- status card ----
    $card = New-Object System.Windows.Forms.Panel
    $card.Location = New-Object System.Drawing.Point(12, 46); $card.Size = New-Object System.Drawing.Size(860, 100)
    $card.BackColor = $App.Theme.AltRow; $card.BorderStyle = 'FixedSingle'
    $st.Lic = & $label 'Checking...' 14 10
    $st.Lic.Font = & $font 15 'Bold'
    $st.Rad = & $label '' 16 46
    $st.Adm = & $label '' 16 70
    $btnRefresh = $App.Theme.MakeButton('Refresh'); $btnRefresh.Location = New-Object System.Drawing.Point(756, 10)
    $btnElevate = $App.Theme.MakeButton('Restart as administrator'); $btnElevate.Location = New-Object System.Drawing.Point(560, 64); $btnElevate.Visible = $false
    $card.Controls.AddRange(@($st.Lic, $st.Rad, $st.Adm, $btnRefresh, $btnElevate))

    # ---- transfer folder ----
    $st.Transfer = & $label '' 12 160 700
    $btnChange = $App.Theme.MakeButton('Change...');  $btnChange.Location = New-Object System.Drawing.Point(700, 154)
    $btnOpen   = $App.Theme.MakeButton('Open');       $btnOpen.Location   = New-Object System.Drawing.Point(792, 154)
    $tHint = & $label 'The transfer folder is what crosses the air gap (a USB stick, say). Change... remembers it on this PC only.' 12 182 840
    $tHint.ForeColor = $App.Theme.Muted

    # ---- the three steps ----
    $sec = { param([string]$t, [int]$y) $l = & $label $t 12 $y; Set-SectionStyle -App $App -Label $l; $l }
    $s1 = & $sec '1.  Save a license request (here)' 216
    $btnRequest = $App.Theme.MakeButton('Save request'); $btnRequest.Location = New-Object System.Drawing.Point(30, 240)
    $btnRequest.Font = & $font 9 'Bold'
    $d1 = & $label ("Runs rserver3.exe /saverequest with this environment's license key. Writes $($st.Me).request to the device folder and to <Transfer>\Requests\.") 150 245 720

    $s2 = & $sec '2.  Activate on a PC with internet access' 290
    $d2 = & $label ("Open https://activate.famatech.com/ , upload $($st.Me).request, and save the $($st.Me).license it returns into <Transfer>\Licenses\ (keep the name). README-ACTIVATION.txt in the transfer folder has the same steps.") 30 314 840

    $s3 = & $sec '3.  Apply the license (here)' 366
    $btnLicense = $App.Theme.MakeButton('Apply license'); $btnLicense.Location = New-Object System.Drawing.Point(30, 390)
    $btnLicense.Font = & $font 9 'Bold'
    $btnBrowse = $App.Theme.MakeButton('Browse for a license file...'); $btnBrowse.Location = New-Object System.Drawing.Point(150, 390)
    $d3 = & $label ("Looks for $($st.Me).license in <Transfer>\Licenses\ (then the transfer folder itself), applies it with rserver3.exe /uselicense and checks the licensed registry key.") 30 426 840

    $top.Controls.AddRange(@($hdr, $card, $st.Transfer, $btnChange, $btnOpen, $tHint, $s1, $btnRequest, $d1, $s2, $d2, $s3, $btnLicense, $btnBrowse, $d3))

    $logHdr = New-Object System.Windows.Forms.Label
    $logHdr.Text = 'Activity'; $logHdr.Dock = 'Top'; $logHdr.Height = 22
    Set-SectionStyle -App $App -Label $logHdr; $logHdr.AutoSize = $false
    $logHdr.Padding = New-Object System.Windows.Forms.Padding(12, 4, 0, 0)

    $st.Log = New-Object System.Windows.Forms.TextBox
    $st.Log.Dock = 'Fill'; $st.Log.Multiline = $true; $st.Log.ReadOnly = $true; $st.Log.ScrollBars = 'Vertical'
    $st.Log.BackColor = $App.Theme.Surface; $st.Log.Font = New-Object System.Drawing.Font($App.Theme.MonoFontName, 9)

    $st.Buttons = @($btnRequest, $btnLicense, $btnBrowse, $btnRefresh)

    # ---------------- helpers ----------------
    $st.Write = {
        param([string]$text)
        $st.Log.AppendText(('{0}  {1}' -f (Get-Date).ToString('HH:mm:ss'), $text) + "`r`n")
    }.GetNewClosure()

    $st.ShowTransfer = {
        $t = & $st.R.TransferPaths -App $st.App -NoCreate
        $st.Transfer.Text = 'Transfer folder:  ' + $t.Root + $(if ($t.Ok) { '' } else { '   (not there yet - made by Save request)' })
        $st.Transfer.ForeColor = $(if ($t.Ok) { $st.App.Theme.Text } else { $st.Amber })
    }.GetNewClosure()

    $st.Show = {
        param($res)
        if (-not $res.RadminFound) {
            $st.Lic.Text = 'Radmin Server 3 is not installed'; $st.Lic.ForeColor = $st.Red
            $st.Rad.Text = 'rserver3.exe was not found (SysWOW64\rserver30, System32\rserver30, or the path set on Environment > Radmin).'
        }
        else {
            $st.Lic.Text = $(if ($res.Licensed) { 'LICENSED' } else { 'NOT LICENSED' })
            $st.Lic.ForeColor = $(if ($res.Licensed) { $st.Green } else { $st.Amber })
            $st.Rad.Text = 'Radmin Server: ' + $res.ExePath
        }
        $st.Adm.Text = 'Running as administrator: ' + $(if ($res.Elevated) { 'yes' } else { 'NO - saving a request or applying a license will probably fail' })
        $st.Adm.ForeColor = $(if ($res.Elevated) { $st.App.Theme.Text } else { $st.Red })
        $btnElevate.Visible = -not $res.Elevated
        $st.Last = $res
    }.GetNewClosure()

    $st.Refresh = {
        $set = & $st.R.Settings -App $st.App
        $res = & $st.R.Local -Action Status -Opt (& $st.R.Options -Settings $set -Action Status)
        & $st.Show $res
        & $st.ShowTransfer
        return $res
    }.GetNewClosure()

    $st.Busy = {
        param([bool]$on)
        foreach ($b in $st.Buttons) { $b.Enabled = -not $on }
        $f = $st.Log.FindForm(); if ($f) { $f.Cursor = $(if ($on) { [System.Windows.Forms.Cursors]::WaitCursor } else { [System.Windows.Forms.Cursors]::Default }) }
        [System.Windows.Forms.Application]::DoEvents()
    }.GetNewClosure()

    $st.ApplyFile = {
        param([string]$file, [bool]$checkName = $true)
        $app = $st.App
        $set = & $st.R.Settings -App $app
        $expect = $(if ($checkName) { [System.IO.Path]::GetFileNameWithoutExtension($file) } else { '' })
        & $st.Write "Applying $file ..."
        & $st.Busy $true
        try {
            $opt = & $st.R.Options -Settings $set -Action License -LicenseBytes ([System.IO.File]::ReadAllBytes($file)) -ExpectedName $expect
            $res = & $st.R.Local -Action License -Opt $opt
            & $st.Write $res.Message
            if ($res.ArgsUsed) { & $st.Write "  (arguments that worked: $($res.ArgsUsed))" }
            $app.LogAction("This machine: apply license $file - $(if ($res.Ok) { 'OK' } else { 'FAILED' }) - $($res.Message)")
            if ($res.Ok -and $res.Licensed) {
                $moved = @(& $st.R.Complete -App $app -Computer $st.Me)
                if ($moved.Count) { & $st.Write ('Moved to Done: ' + ($moved -join ', ')) }
                $app.SetStatus('Licensed.', 'ok')
            } else { $app.SetStatus($res.Message, $(if ($res.Ok) { 'ok' } else { 'err' })) }
        }
        catch { & $st.Write "Error: $($_.Exception.Message)"; $app.SetStatus($_.Exception.Message, 'err') }
        finally { & $st.Busy $false; [void](& $st.Refresh) }
    }.GetNewClosure()

    # ---------------- events ----------------
    $btnRefresh.Add_Click({ $r = & $st.Refresh; & $st.Write ("Status: " + $r.Message) }.GetNewClosure())

    $btnElevate.Add_Click({
        try {
            Start-Process -FilePath $st.App.ExePath -Verb RunAs -ErrorAction Stop
            $f = $st.Log.FindForm(); if ($f) { $f.Close() }
        }
        catch { & $st.Write "Not restarted: $($_.Exception.Message)" }
    }.GetNewClosure())

    $btnRequest.Add_Click({
        $app = $st.App
        $set = & $st.R.Settings -App $app
        if (-not [string]$set.LicenseKey) {
            [void][System.Windows.Forms.MessageBox]::Show('No Radmin license key is set for this environment.' + "`r`n`r`n" + 'Set it on Environment > Radmin (admin password or developer build).', 'Save request', 'OK', 'Warning')
            return
        }
        $force = $false
        if ($st.Last -and $st.Last.Licensed) {
            if ([System.Windows.Forms.MessageBox]::Show('This machine is already licensed. Make a request anyway?', 'Save request', 'YesNo', 'Question') -ne 'Yes') { return }
            $force = $true
        }
        $t = & $st.R.TransferPaths -App $app
        if (-not $t.Ok) { & $st.Write $t.Error; $app.SetStatus($t.Error, 'err'); return }
        & $st.Write 'Saving license request ...'
        & $st.Busy $true
        try {
            $res = & $st.R.Local -Action Request -Opt (& $st.R.Options -Settings $set -Action Request -Force:$force)
            & $st.Write $res.Message
            if ($res.Ok -and -not $res.Skipped) {
                $p = & $st.R.SaveRequest -App $app -Result $res -Source 'This machine'
                & $st.Write "Copied to $p"
                & $st.Write 'Next: take the transfer folder to an internet PC (step 2).'
                if ($res.ArgsUsed -and $res.ArgsUsed -ne $set.SaveRequestArgs) { & $st.Write "  (worked with: $($res.ArgsUsed) - set this on Environment > Radmin to skip the first try)" }
                $app.SetStatus("Request saved: $p", 'ok')
            } else { $app.SetStatus($res.Message, $(if ($res.Ok) { 'ok' } else { 'err' })) }
            $app.LogAction("This machine: save request - $(if ($res.Ok) { 'OK' } else { 'FAILED' }) - $($res.Message)")
        }
        catch { & $st.Write "Error: $($_.Exception.Message)"; $app.SetStatus($_.Exception.Message, 'err') }
        finally { & $st.Busy $false; [void](& $st.Refresh) }
    }.GetNewClosure())

    $btnLicense.Add_Click({
        $f = & $st.R.FindLicense -App $st.App -Names @($st.Me)
        if (-not $f) {
            $t = & $st.R.TransferPaths -App $st.App -NoCreate
            & $st.Write "No $($st.Me).license in $($t.Licenses) or $($t.Root)."
            $st.App.SetStatus("No $($st.Me).license found - use Browse for a license file...", 'warn')
            return
        }
        & $st.ApplyFile $f $true
    }.GetNewClosure())

    $btnBrowse.Add_Click({
        $d = New-Object System.Windows.Forms.OpenFileDialog
        $d.Title = 'Radmin license file'; $d.Filter = 'Radmin license (*.license)|*.license|All files (*.*)|*.*'
        $t = & $st.R.TransferPaths -App $st.App -NoCreate
        if (Test-Path -LiteralPath $t.Licenses) { $d.InitialDirectory = $t.Licenses }
        if ($d.ShowDialog() -eq 'OK') {
            $file = $d.FileName
            $check = $true
            $name = [System.IO.Path]::GetFileNameWithoutExtension($file)
            if ($name -ne $st.Me) {
                $q = "This file is named '$name', but this machine is '$($st.Me)'. A license only works on the machine it was made for." + "`r`n`r`n" + 'Apply it anyway?'
                if ([System.Windows.Forms.MessageBox]::Show($q, 'Apply license', 'YesNo', 'Warning') -ne 'Yes') { $d.Dispose(); return }
                $check = $false
            }
            & $st.ApplyFile $file $check
        }
        $d.Dispose()
    }.GetNewClosure())

    $btnOpen.Add_Click({
        $t = & $st.R.TransferPaths -App $st.App
        if ($t.Ok) { try { Start-Process explorer.exe ('"{0}"' -f $t.Root) } catch { } } else { & $st.Write $t.Error }
        & $st.ShowTransfer
    }.GetNewClosure())

    $btnChange.Add_Click({
        $d = New-Object System.Windows.Forms.FolderBrowserDialog
        $d.Description = 'Transfer folder (e.g. the USB stick). Requests, Licenses and Done are made inside it.'
        $d.SelectedPath = (& $st.R.TransferFolder -App $st.App)
        if ($d.ShowDialog() -eq 'OK') {
            & $st.R.SetTransfer -App $st.App -Path $d.SelectedPath
            & $st.Write "Transfer folder on this PC: $($d.SelectedPath)"
            $st.App.LogAction("This machine: transfer folder set to $($d.SelectedPath)")
            & $st.ShowTransfer
        }
        $d.Dispose()
    }.GetNewClosure())

    Register-EnvironmentChangedHandler -Handler { param($a) try { [void](& $st.Refresh) } catch { } }.GetNewClosure()

    # Dock order: Fill first, then the Top bands.
    $Page.Controls.Add($st.Log)
    $Page.Controls.Add($logHdr)
    $Page.Controls.Add($top)

    $res = & $st.Refresh
    & $st.Write ("Status: " + $res.Message + $(if ($res.RadminFound) { "  ($($res.ExePath))" } else { '' }))
}
