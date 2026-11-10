# UI_Env_SccmSite.psm1   (LITE TIER)
#
# "SCCM Site" page on the Environment tab: the per-site settings of one
# environment. Saved with the tab's Save button (the page never saves itself).
# Blank fields fall back to the v8 settings file when its site code matches.

function Register-SamEnvironmentPage {
    Register-EnvironmentSection -Title 'SCCM Site' -Order 10 -Build {
        param($Page, $App)
        $boxes = [ordered]@{}
        $y = 12

        $note = New-Object System.Windows.Forms.Label
        $note.Location = New-Object System.Drawing.Point(12, $y); $note.Size = New-Object System.Drawing.Size(900, 34); $note.ForeColor = $App.Theme.Muted
        $note.Text = 'One environment = one SCCM site. Blank Local Root = the folder the EXE is in (relative paths are relative to it). Blank SMS Provider = detected from the ConfigMgr console.'
        $Page.Controls.Add($note); $y += 42

        $fields = @(
            @{ Key = 'SiteCode';       Caption = 'Site code';                        Width = 80;  Browse = $false },
            @{ Key = 'SiteServer';     Caption = 'SMS Provider server';              Width = 300; Browse = $false },
            @{ Key = 'LocalRoot';      Caption = 'Local Root (JSON + local content)'; Width = 520; Browse = $true },
            @{ Key = 'IncomingPath';   Caption = 'Incoming share (new versions)';    Width = 520; Browse = $true },
            @{ Key = 'RepositoryPath'; Caption = 'Repository share (content source)'; Width = 520; Browse = $true },
            @{ Key = 'IconsPath';      Caption = 'Icons folder';                     Width = 520; Browse = $true },
            @{ Key = 'TestCollection'; Caption = 'Default test collection';          Width = 300; Browse = $false },
            @{ Key = 'DPGroup';        Caption = 'Distribution point group';         Width = 300; Browse = $false },
            @{ Key = 'RobocopyThreads'; Caption = 'Robocopy threads (/MT)';          Width = 80;  Browse = $false })
        foreach ($f in $fields) {
            $l = New-Object System.Windows.Forms.Label
            $l.Text = $f.Caption + ':'; $l.Location = New-Object System.Drawing.Point(12, ($y + 3)); $l.AutoSize = $true
            $t = New-Object System.Windows.Forms.TextBox
            $t.Location = New-Object System.Drawing.Point(260, $y); $t.Width = $f.Width
            $Page.Controls.Add($l); $Page.Controls.Add($t)
            if ($f.Browse) {
                $b = New-Object System.Windows.Forms.Button
                $b.Text = '...'; $b.Size = New-Object System.Drawing.Size(32, 23); $b.Location = New-Object System.Drawing.Point((265 + $f.Width), ($y - 1))
                $box = $t
                $b.Add_Click({
                    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
                    if ($box.Text -and [IO.Directory]::Exists($box.Text)) { $dlg.SelectedPath = $box.Text }
                    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $box.Text = $dlg.SelectedPath }
                }.GetNewClosure())
                $Page.Controls.Add($b)
            }
            $boxes[$f.Key] = $t
            $y += 30
        }
        $chkPrune = New-Object System.Windows.Forms.CheckBox
        $chkPrune.Text = 'After "Pull from Incoming", remove older local version folders (never one that is not yet in the repository)'
        $chkPrune.Location = New-Object System.Drawing.Point(260, $y); $chkPrune.AutoSize = $true
        $Page.Controls.Add($chkPrune); $y += 26
        $chkReload = New-Object System.Windows.Forms.CheckBox
        $chkReload.Text = 'Reload data every time a tab is selected (off = load once; use Refresh / F5)'
        $chkReload.Location = New-Object System.Drawing.Point(260, $y); $chkReload.AutoSize = $true
        $Page.Controls.Add($chkReload); $y += 36

        $btnTest = New-Object System.Windows.Forms.Button
        $btnTest.Text = 'Test connection'; $btnTest.Size = New-Object System.Drawing.Size(130, 28); $btnTest.Location = New-Object System.Drawing.Point(260, $y)
        $btnDetect = New-Object System.Windows.Forms.Button
        $btnDetect.Text = 'Detect server'; $btnDetect.Size = New-Object System.Drawing.Size(120, 28); $btnDetect.Location = New-Object System.Drawing.Point(398, $y)
        $Page.Controls.Add($btnTest); $Page.Controls.Add($btnDetect); $y += 36
        $lblResult = New-Object System.Windows.Forms.Label
        $lblResult.Location = New-Object System.Drawing.Point(260, $y); $lblResult.Size = New-Object System.Drawing.Size(700, 60)
        $Page.Controls.Add($lblResult); $y += 64
        $lblRoot = New-Object System.Windows.Forms.Label
        $lblRoot.Location = New-Object System.Drawing.Point(260, $y); $lblRoot.Size = New-Object System.Drawing.Size(700, 40); $lblRoot.ForeColor = $App.Theme.Muted
        $Page.Controls.Add($lblRoot)

        $btnTest.Add_Click({
            $site = $boxes['SiteCode'].Text.Trim().ToUpper(); $srv = $boxes['SiteServer'].Text.Trim()
            if (-not $site -or -not $srv) { $lblResult.ForeColor = [System.Drawing.Color]::Firebrick; $lblResult.Text = 'Enter a site code and an SMS Provider server first (or use Detect server).'; return }
            $frm = $Page.FindForm(); if ($frm) { $frm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor }
            $cim = $null
            try {
                $cim = New-CimSession -ComputerName $srv -SessionOption (New-CimSessionOption -Protocol Dcom) -ErrorAction Stop
                $x = Get-CimInstance -CimSession $cim -Namespace "root\SMS\site_$site" -Query ("SELECT SiteCode, SiteName, Version FROM SMS_Site WHERE SiteCode = '{0}'" -f $site) -ErrorAction Stop | Select-Object -First 1
                if (-not $x) { throw "site $site was not found on $srv" }
                $lblResult.ForeColor = [System.Drawing.Color]::DarkGreen
                $lblResult.Text = "OK - site $($x.SiteCode) '$($x.SiteName)', version $($x.Version), on $srv."
            }
            catch { $lblResult.ForeColor = [System.Drawing.Color]::Firebrick; $lblResult.Text = "Failed: $($_.Exception.Message)" }
            finally {
                if ($cim) { Remove-CimSession -CimSession $cim -ErrorAction SilentlyContinue }
                if ($frm) { $frm.Cursor = [System.Windows.Forms.Cursors]::Default }
            }
        }.GetNewClosure())

        $btnDetect.Add_Click({
            $frm = $Page.FindForm(); if ($frm) { $frm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor }
            try {
                Import-SamCMModule
                $drives = @(Get-PSDrive -PSProvider CMSite -ErrorAction SilentlyContinue)
                if (-not $drives.Count) { throw 'the ConfigMgr console has no site connection (no CMSite drive).' }
                $site = $boxes['SiteCode'].Text.Trim().ToUpper()
                $hit = @($drives | Where-Object { $_.Name -ieq $site }) | Select-Object -First 1
                if (-not $hit -and -not $site -and $drives.Count -eq 1) { $hit = $drives[0]; $boxes['SiteCode'].Text = $hit.Name }
                if ($hit) { $boxes['SiteServer'].Text = [string]$hit.Root }
                $list = ($drives | ForEach-Object { "$($_.Name) = $($_.Root)" }) -join ', '
                $lblResult.ForeColor = $(if ($hit) { [System.Drawing.Color]::DarkGreen } else { [System.Drawing.Color]::DarkOrange })
                $lblResult.Text = $(if ($hit) { "Detected $($hit.Root) for site $($hit.Name). Console sites: $list" } else { "No console connection for site '$site'. Console sites: $list" })
            }
            catch { $lblResult.ForeColor = [System.Drawing.Color]::Firebrick; $lblResult.Text = "Detect failed: $($_.Exception.Message)" }
            finally { if ($frm) { $frm.Cursor = [System.Windows.Forms.Cursors]::Default } }
        }.GetNewClosure())

        @{
            Load = {
                param($Record)
                foreach ($k in @($boxes.Keys)) { $boxes[$k].Text = [string](Get-SamRecordValue $Record $k '') }
                if (-not $boxes['RobocopyThreads'].Text) { $boxes['RobocopyThreads'].Text = '8' }
                $p = Get-SamRecordValue $Record 'PruneOldLocalVersions' $true
                $chkPrune.Checked = ([string]$p -ne 'False' -and [string]$p -ne '0')
                $rl = Get-SamRecordValue $Record 'ReloadOnTabSelect' $true
                $chkReload.Checked = ([string]$rl -ne 'False' -and [string]$rl -ne '0')
                $lblResult.Text = ''
                $eff = Get-SamSettings -Record $Record
                $lblRoot.Text = "Local Root in use: $($eff.LocalRootResolved)" + $(if (-not $Record['SiteServer'] -and $eff.SiteServer) { "`r`nSMS Provider from the v8 settings file: $($eff.SiteServer)" } else { '' })
            }.GetNewClosure()
            Collect = {
                param($Record)
                $h = [ordered]@{}
                foreach ($k in @($boxes.Keys)) { $h[$k] = $boxes[$k].Text.Trim() }
                $h['SiteCode'] = $h['SiteCode'].ToUpper()
                $n = 0; if ([int]::TryParse($h['RobocopyThreads'], [ref]$n)) { $h['RobocopyThreads'] = $n }
                $h['PruneOldLocalVersions'] = [bool]$chkPrune.Checked
                $h['ReloadOnTabSelect'] = [bool]$chkReload.Checked
                return $h
            }.GetNewClosure()
            Validate = {
                param($Record)
                $sc = $boxes['SiteCode'].Text.Trim()
                if ($sc -and $sc -notmatch '^[A-Za-z0-9]{3}$') { return 'The site code is three letters / digits (for example A30).' }
                $n = 0
                if (-not [int]::TryParse($boxes['RobocopyThreads'].Text.Trim(), [ref]$n) -or $n -lt 1 -or $n -gt 128) { return 'Robocopy threads must be a whole number from 1 to 128.' }
                return ''
            }.GetNewClosure()
        }
    }
}
