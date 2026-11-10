# UI_Tab_Drivers.psm1   (LITE TIER)
#
# The Drivers tab - the main work page:
#   1. Device registry data  paste rows (or load the CSV), Build preview
#   2. Preview               one row per driver + IP; pick sites, edit names/IPs,
#                            then Add to this PC or Overwrite this PC
#   3. Drivers on this PC    the AB_ETH drivers in the registry; remove IPs;
#                            backups (save / restore to preview / delete)
#
# Drivers are grouped by site (Lease) and VLAN: the name comes from the VLAN
# lookup table (VLAN Lookup tab), e.g. BL(25)SCADA. Every change to the
# registry first saves a backup of the current drivers.
#
# Event handlers are plain script blocks (no .GetNewClosure()), so they run in
# this module's scope and share the state in $script:D.

$script:D = $null

function New-DriversTab {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.TabPage]$Page,
        [Parameter(Mandatory)] $App
    )
    Set-LazyTabBuild -Page $Page -App $App -Build { param($Page, $App) Initialize-DrvTab -Page $Page -App $App }
}

# ---------------------------------------------------------------------------
#  build
# ---------------------------------------------------------------------------
function Initialize-DrvTab {
    param($Page, $App)
    $T = $App.Theme
    $script:D = @{
        App = $App; Page = $Page
        Preview = New-Object System.Collections.ArrayList     # every preview row (the grid shows a filtered copy)
        Current = @(); CurrentRows = @(); Backups = @(); BackupDir = $null
        Filling = $false; IsAdmin = (Test-RSLinxAdministrator)
    }
    $Page.AutoScroll = $false
    $Page.Padding = New-Object System.Windows.Forms.Padding(8, 6, 8, 6)

    # ---- admin band ----
    $band = $null
    if (-not $script:D.IsAdmin) {
        $band = New-Object System.Windows.Forms.Panel
        $band.Dock = 'Top'; $band.Height = 40
        $band.BackColor = [System.Drawing.Color]::FromArgb(255, 244, 206)
        $bl = New-Object System.Windows.Forms.Label
        $bl.AutoSize = $true; $bl.Location = New-Object System.Drawing.Point(10, 11)
        $bl.ForeColor = [System.Drawing.Color]::FromArgb(110, 70, 0)
        $bl.Text = 'Not running as administrator: you can preview and back up, but adding or removing drivers needs elevation.'
        $bb = $T.MakeButton('Restart as administrator')
        $bb.Location = New-Object System.Drawing.Point(720, 6)
        $bb.Add_Click({ Invoke-DrvRestartElevated })
        $band.Controls.AddRange(@($bl, $bb))
    }

    # ---- status log (bottom) ----
    $logPanel = New-Object System.Windows.Forms.Panel
    $logPanel.Dock = 'Bottom'; $logPanel.Height = 130
    $logBox = New-Object System.Windows.Forms.TextBox
    $logBox.Multiline = $true; $logBox.ReadOnly = $true; $logBox.ScrollBars = 'Vertical'; $logBox.Dock = 'Fill'
    $logBox.BackColor = $T.Surface; $logBox.Font = New-Object System.Drawing.Font($T.MonoFontName, 8.5)
    $logPanel.Controls.Add($logBox)
    $logPanel.Controls.Add((New-RSLinxHeader -App $App -Text 'Activity' -Section))
    $script:D.Log = $logBox

    # ---- three columns ----
    $table = New-Object System.Windows.Forms.TableLayoutPanel
    $table.Dock = 'Fill'; $table.ColumnCount = 3; $table.RowCount = 1
    [void]$table.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 26)))
    [void]$table.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 46)))
    [void]$table.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 28)))
    [void]$table.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))

    $table.Controls.Add((New-DrvImportColumn -App $App), 0, 0)
    $table.Controls.Add((New-DrvPreviewColumn -App $App), 1, 0)
    $table.Controls.Add((New-DrvCurrentColumn -App $App), 2, 0)

    $Page.Controls.Add($table)
    $Page.Controls.Add($logPanel)
    if ($band) { $Page.Controls.Add($band) }

    if ($script:D.IsAdmin) { Write-DrvLog 'Running as administrator.' }
    else { Write-DrvLog 'Not running as administrator - Add, Overwrite and Remove are disabled.' }
    Update-DrvCurrent
    Update-DrvBackupList
    Update-DrvPreviewSummary

    # another environment = maybe another backup folder
    Register-EnvironmentChangedHandler -Handler { param($App) if ($script:D) { Update-DrvBackupList -Refresh } }
}

function New-DrvColumnPanel {
    $p = New-Object System.Windows.Forms.Panel
    $p.Dock = 'Fill'; $p.Margin = New-Object System.Windows.Forms.Padding(4, 0, 4, 4)
    return $p
}

function New-DrvImportColumn {
    param($App)
    $T = $App.Theme
    $col = New-DrvColumnPanel

    $hint = New-Object System.Windows.Forms.Label
    $hint.Dock = 'Top'; $hint.Height = 50; $hint.ForeColor = $T.Muted
    $mfr = Get-DrvManufacturer
    $hint.Text = "Paste rows from the device registry CSV (header row optional) or load the file. Only '$mfr' devices are used; Primary and Secondary IPs each become a driver node. A Name,Node list (old RSLinx.csv / a backup) also works."

    $btnLoad  = $T.MakeButton('Load CSV file...')
    $btnPaste = $T.MakeButton('Paste clipboard')
    $btnClear = $T.MakeButton('Clear')
    $topBar = New-RSLinxButtonBar -App $App -Buttons @($btnLoad, $btnPaste, $btnClear) -Dock 'Top' -Height 36

    $box = New-Object System.Windows.Forms.TextBox
    $box.Multiline = $true; $box.MaxLength = 0; $box.WordWrap = $false; $box.ScrollBars = 'Both'
    $box.AcceptsTab = $true; $box.Dock = 'Fill'; $box.HideSelection = $false
    $box.Font = New-Object System.Drawing.Font($T.MonoFontName, 8.5)
    $script:D.PasteBox = $box

    $opts = New-Object System.Windows.Forms.Panel
    $opts.Dock = 'Bottom'; $opts.Height = 96
    $chkSec = New-Object System.Windows.Forms.CheckBox
    $chkSec.Text = 'Include Secondary IPs'; $chkSec.Checked = $true; $chkSec.AutoSize = $true
    $chkSec.Location = New-Object System.Drawing.Point(2, 8)
    $chkInact = New-Object System.Windows.Forms.CheckBox
    $chkInact.Text = 'Include inactive devices'; $chkInact.Checked = $false; $chkInact.AutoSize = $true
    $chkInact.Location = New-Object System.Drawing.Point(180, 8)
    $btnBuild = $T.MakeButton('Build preview')
    $btnBuild.Location = New-Object System.Drawing.Point(2, 36)
    $btnBuild.Font = New-Object System.Drawing.Font($T.FontName, ($T.FontSizePt + 1), [System.Drawing.FontStyle]::Bold)
    $lines = New-Object System.Windows.Forms.Label
    $lines.AutoSize = $true; $lines.ForeColor = $T.Muted; $lines.Location = New-Object System.Drawing.Point(4, 74)
    $opts.Controls.AddRange(@($chkSec, $chkInact, $btnBuild, $lines))
    $script:D.ChkSecondary = $chkSec; $script:D.ChkInactive = $chkInact; $script:D.PasteInfo = $lines

    $box.Add_TextChanged({ Update-DrvPasteInfo })
    $btnLoad.Add_Click({ Invoke-DrvLoadFile })
    $btnPaste.Add_Click({
        try { $t = [System.Windows.Forms.Clipboard]::GetText() } catch { $t = '' }
        if (-not $t) { $script:D.App.SetStatus('The clipboard has no text.', 'warn'); return }
        $script:D.PasteBox.Text = $t
    })
    $btnClear.Add_Click({ $script:D.PasteBox.Clear() })
    $btnBuild.Add_Click({ Invoke-DrvBuildPreview })

    $col.Controls.Add($box)
    $col.Controls.Add($opts)
    $col.Controls.Add($topBar)
    $col.Controls.Add($hint)
    $col.Controls.Add((New-RSLinxHeader -App $App -Text '1. Device registry data'))
    return $col
}

function New-DrvPreviewColumn {
    param($App)
    $T = $App.Theme
    $col = New-DrvColumnPanel

    $fb = New-RSLinxFilterBar -App $App
    $script:D.PreviewCount = $fb.Count

    # site picker
    $sites = New-Object System.Windows.Forms.Panel
    $sites.Dock = 'Top'; $sites.Height = 58
    $sl = New-Object System.Windows.Forms.Label
    $sl.Text = 'Sites:'; $sl.AutoSize = $true; $sl.Location = New-Object System.Drawing.Point(0, 6)
    $clb = New-Object System.Windows.Forms.CheckedListBox
    $clb.Location = New-Object System.Drawing.Point(46, 2); $clb.Size = New-Object System.Drawing.Size(520, 52)
    $clb.MultiColumn = $true; $clb.ColumnWidth = 120; $clb.CheckOnClick = $true; $clb.IntegralHeight = $false
    $clb.BorderStyle = 'FixedSingle'
    $bAll = $T.MakeButton('All'); $bAll.Location = New-Object System.Drawing.Point(576, 2)
    $bNone = $T.MakeButton('None'); $bNone.Location = New-Object System.Drawing.Point(576, 30)
    $sites.Controls.AddRange(@($sl, $clb, $bAll, $bNone))
    $script:D.Sites = $clb
    # ItemCheck fires before the box changes: filter once, after it (and after a run of changes).
    $clb.Add_ItemCheck({
        if ($script:D.SitesBusy -or $script:D.SitesPending) { return }
        $script:D.SitesPending = $true
        [void]$script:D.Sites.BeginInvoke([System.Windows.Forms.MethodInvoker]{ $script:D.SitesPending = $false; Invoke-DrvPreviewFilter })
    })
    $bAll.Add_Click({ Set-DrvAllSites -Checked $true })
    $bNone.Add_Click({ Set-DrvAllSites -Checked $false })

    $grid = New-RSLinxGrid -App $App -MultiSelect
    [void](Add-RSLinxGridColumn -Grid $grid -Name 'Include' -Header 'Use' -Width 40 -CheckBox)
    [void](Add-RSLinxGridColumn -Grid $grid -Name 'Driver' -Header 'Driver name' -Width 130)
    [void](Add-RSLinxGridColumn -Grid $grid -Name 'IP' -Header 'IP address' -Width 110)
    [void](Add-RSLinxGridColumn -Grid $grid -Name 'Site' -Width 40 -ReadOnly)
    [void](Add-RSLinxGridColumn -Grid $grid -Name 'Asset' -Width 110 -ReadOnly)
    [void](Add-RSLinxGridColumn -Grid $grid -Name 'Source' -Header 'IP' -Width 70 -ReadOnly)
    [void](Add-RSLinxGridColumn -Grid $grid -Name 'Model' -Width 110 -ReadOnly)
    [void](Add-RSLinxGridColumn -Grid $grid -Name 'Description' -Fill 60 -ReadOnly)
    [void](Add-RSLinxGridColumn -Grid $grid -Name 'Match' -Header 'VLAN match' -Width 70 -ReadOnly)
    [void](Add-RSLinxGridColumn -Grid $grid -Name 'Note' -Fill 40 -ReadOnly)
    $grid.Columns['Driver'].DefaultCellStyle.Font = New-Object System.Drawing.Font($T.FontName, $T.FontSizePt, [System.Drawing.FontStyle]::Bold)
    $script:D.PreviewGrid = $grid
    $grid.Add_CurrentCellDirtyStateChanged({
        $g = $script:D.PreviewGrid
        if ($g.IsCurrentCellDirty -and $g.CurrentCell -is [System.Windows.Forms.DataGridViewCheckBoxCell]) { [void]$g.CommitEdit('CurrentCellChange') }
    })
    $grid.Add_CellValueChanged({ param($s, $e) Invoke-DrvPreviewCellChanged -RowIndex $e.RowIndex -ColumnIndex $e.ColumnIndex })

    # bottom: summary + actions
    $bottom = New-Object System.Windows.Forms.Panel
    $bottom.Dock = 'Bottom'; $bottom.Height = 70
    $sum = New-Object System.Windows.Forms.Label
    $sum.AutoSize = $true; $sum.Location = New-Object System.Drawing.Point(0, 6)
    $sum.Font = New-Object System.Drawing.Font($T.FontName, $T.FontSizePt, [System.Drawing.FontStyle]::Bold); $sum.ForeColor = $T.Title
    $script:D.PreviewSummary = $sum
    $bAdd  = $T.MakeButton('Add to this PC')
    $bOver = $T.MakeButton('Overwrite this PC')
    $bTick = $T.MakeButton('Use selected')
    $bUntick = $T.MakeButton('Skip selected')
    $bRem  = $T.MakeButton('Remove selected rows')
    $bClr  = $T.MakeButton('Clear preview')
    $bar = New-RSLinxButtonBar -App $App -Buttons @($bAdd, $bOver, $bTick, $bUntick, $bRem, $bClr) -Dock 'Bottom' -Height 38
    $bottom.Controls.Add($bar); $bottom.Controls.Add($sum)
    $script:D.BtnAdd = $bAdd; $script:D.BtnOverwrite = $bOver
    $bAdd.Add_Click({ Invoke-DrvApply -Mode 'Add' })
    $bOver.Add_Click({ Invoke-DrvApply -Mode 'Overwrite' })
    $bTick.Add_Click({ Set-DrvSelectedInclude -Value $true })
    $bUntick.Add_Click({ Set-DrvSelectedInclude -Value $false })
    $bRem.Add_Click({ Remove-DrvSelectedPreviewRows })
    $bClr.Add_Click({
        if ($script:D.Preview.Count -eq 0) { return }
        if ((Show-DrvQuestion "Clear all $($script:D.Preview.Count) preview row(s)?") -ne 'Yes') { return }
        Set-DrvPreview -Rows @()
    })

    $legend = New-Object System.Windows.Forms.Label
    $legend.Dock = 'Top'; $legend.Height = 20; $legend.ForeColor = $T.Muted
    $legend.Text = 'Yellow name = no VLAN lookup entry (default SITE(octet)SCADA).  Red row = cannot be applied (see Note).  Driver name and IP can be edited.'

    $col.Controls.Add($grid)
    $col.Controls.Add($bottom)
    $col.Controls.Add($legend)
    $col.Controls.Add($sites)
    $col.Controls.Add($fb.Panel)
    $col.Controls.Add((New-RSLinxHeader -App $App -Text '2. Preview - drivers to apply'))

    $script:D.PreviewFilter = Register-ListFilter -App $App -TextBox $fb.Box -OnFilter { param($Regex, $Text) Update-DrvPreviewGrid -Regex $Regex }
    return $col
}

function New-DrvCurrentColumn {
    param($App)
    $T = $App.Theme
    $col = New-DrvColumnPanel

    $fb = New-RSLinxFilterBar -App $App -BoxWidth 180
    $script:D.CurrentCount = $fb.Count

    $grid = New-RSLinxGrid -App $App -ReadOnly -MultiSelect
    [void](Add-RSLinxGridColumn -Grid $grid -Name 'Driver' -Header 'Driver name' -Fill 50)
    [void](Add-RSLinxGridColumn -Grid $grid -Name 'IP' -Header 'IP address' -Fill 40)
    [void](Add-RSLinxGridColumn -Grid $grid -Name 'Key' -Header 'Registry key' -Width 80)
    $script:D.CurrentGrid = $grid

    $bRef = $T.MakeButton('Refresh')
    $bRem = $T.MakeButton('Remove selected IPs')
    $bCopy = $T.MakeButton('Copy to preview')
    $bar = New-RSLinxButtonBar -App $App -Buttons @($bRef, $bRem, $bCopy) -Dock 'Bottom' -Height 38
    $script:D.BtnRemove = $bRem
    $bRef.Add_Click({ Update-DrvCurrent; Update-DrvBackupList -Refresh })
    $bRem.Add_Click({ Invoke-DrvRemoveSelected })
    $bCopy.Add_Click({ Copy-DrvCurrentToPreview })

    # ---- backups ----
    $bk = New-Object System.Windows.Forms.Panel
    $bk.Dock = 'Bottom'; $bk.Height = 270
    $bkDir = New-Object System.Windows.Forms.Label
    $bkDir.Dock = 'Top'; $bkDir.Height = 34; $bkDir.ForeColor = $T.Muted
    $script:D.BackupDirLabel = $bkDir
    $bfb = New-RSLinxFilterBar -App $App -BoxWidth 180
    $script:D.BackupCount = $bfb.Count
    $list = New-Object System.Windows.Forms.ListBox
    $list.Dock = 'Fill'; $list.IntegralHeight = $false; $list.HorizontalScrollbar = $true
    $list.Font = New-Object System.Drawing.Font($T.MonoFontName, 8.5)
    $script:D.BackupList = $list
    $bSave = $T.MakeButton('Save current')
    $bRestore = $T.MakeButton('Restore to preview')
    $bDel = $T.MakeButton('Delete')
    $bOpen = $T.MakeButton('Open folder')
    $bkBar = New-RSLinxButtonBar -App $App -Buttons @($bSave, $bRestore, $bDel, $bOpen) -Dock 'Bottom' -Height 38
    $bSave.Add_Click({ Invoke-DrvSaveBackup })
    $bRestore.Add_Click({ Invoke-DrvRestoreBackup })
    $bDel.Add_Click({ Remove-DrvBackup })
    $bOpen.Add_Click({
        if (-not $script:D.BackupDir) { return }
        $r = Invoke-AppCommand -App $script:D.App -Title 'Open backup folder' -Kind Read -RunLabel 'Open' -Summary "Open $($script:D.BackupDir) in Explorer." `
            -Code ('Start-Process -FilePath explorer.exe -ArgumentList ' + (Format-AppCommandValue ('"' + $script:D.BackupDir + '"')))
        if ($r.Errors.Count) { $script:D.App.SetStatus("Not opened: $($r.Errors[0])", 'err') }
    })
    $list.Add_DoubleClick({ Invoke-DrvRestoreBackup })
    $bk.Controls.Add($list)
    $bk.Controls.Add($bkBar)
    $bk.Controls.Add($bfb.Panel)
    $bk.Controls.Add($bkDir)
    $bk.Controls.Add((New-RSLinxHeader -App $App -Text 'Backups' -Section))

    if (-not $script:D.IsAdmin) { $bRem.Enabled = $false }

    $col.Controls.Add($grid)
    $col.Controls.Add($bar)
    $col.Controls.Add($bk)
    $col.Controls.Add($fb.Panel)
    $col.Controls.Add((New-RSLinxHeader -App $App -Text '3. Drivers on this PC'))

    $script:D.CurrentFilter = Register-ListFilter -App $App -TextBox $fb.Box -OnFilter { param($Regex, $Text) Update-DrvCurrentGrid -Regex $Regex }
    $script:D.BackupFilter  = Register-ListFilter -App $App -TextBox $bfb.Box -OnFilter { param($Regex, $Text) Update-DrvBackupListBox -Regex $Regex }
    return $col
}

# ---------------------------------------------------------------------------
#  helpers
# ---------------------------------------------------------------------------
function Write-DrvLog {
    param([string]$Text, [string]$Level = 'INFO')
    $App = $script:D.App
    $line = '[{0}] {1}' -f (Get-Date).ToString('HH:mm:ss'), $Text
    if ($Level -ne 'INFO') { $line = '[{0}] {1}: {2}' -f (Get-Date).ToString('HH:mm:ss'), $Level, $Text }
    try { $script:D.Log.AppendText($line + "`r`n") } catch { }
    try { $App.Log($Level, 'Drivers', $Text) } catch { }
}

function Show-DrvQuestion {
    param([string]$Text, [string]$Icon = 'Question')
    return [string][System.Windows.Forms.MessageBox]::Show($script:D.Page.FindForm(), $Text, 'RSLinx Driver Manager',   # not-a-command: preview questions only
        [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]$Icon)
}

function Show-DrvMessage {
    param([string]$Text, [string]$Icon = 'Information')
    [void][System.Windows.Forms.MessageBox]::Show($script:D.Page.FindForm(), $Text, 'RSLinx Driver Manager',
        [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]$Icon)
}

function Get-DrvManufacturer {
    $m = ([string]$script:D.App.GetSetting('ManufacturerMatch')).Trim()
    if ($m -eq '') { $m = 'Allen-Bradley' }
    return $m
}

function Invoke-DrvRestartElevated {
    $App = $script:D.App
    $r = Invoke-AppCommand -App $App -Title 'Restart as administrator' -Kind Read -RunLabel 'Restart' `
        -Summary 'Start this app again as administrator (Windows asks for consent), then close this copy.' `
        -Code ('Start-Process -FilePath ' + (Format-AppCommandValue ([string]$App.ExePath)) + ' -Verb RunAs -ErrorAction Stop')
    if (-not $r.Ran) { return }
    if ($r.Errors.Count) { $App.SetStatus('Not restarted: elevation was cancelled or failed.', 'warn'); return }
    $App.Log('INFO', 'Drivers', 'Restarting elevated.')
    $f = $script:D.Page.FindForm(); if ($f) { $f.Close() }
}

# The command window is the confirmation for every change (template rule: every action shows its code).
function Confirm-DrvChange {
    param([string]$Title, [string]$Summary, [string]$Code)
    return (Confirm-AppCommand -App $script:D.App -Title $Title -Kind Change -RunLabel 'Apply' -Summary $Summary -Code $Code)
}

function Get-DrvBackupNote {
    $dir = $script:D.BackupDir
    if (-not $dir) { try { $dir = (Get-RSLinxBackupDir -App $script:D.App).Path } catch { $dir = '<backup folder>' } }
    return "The app first saves the current drivers to a CSV backup in $dir"
}

function Update-DrvPasteInfo {
    $t = $script:D.PasteBox.Text
    if (-not $t) { $script:D.PasteInfo.Text = 'Nothing pasted yet.'; return }
    $n = ([regex]::Matches($t, "`n")).Count + 1
    $script:D.PasteInfo.Text = '{0:N0} line(s), {1:N0} characters' -f $n, $t.Length
}

# ---------------------------------------------------------------------------
#  1. import
# ---------------------------------------------------------------------------
function Invoke-DrvLoadFile {
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'CSV / text files (*.csv;*.txt;*.tsv)|*.csv;*.txt;*.tsv|All files (*.*)|*.*'
    $dlg.Title = 'Device registry CSV'
    if ($dlg.ShowDialog($script:D.Page.FindForm()) -ne 'OK') { return }
    try {
        $script:D.PasteBox.Text = [System.IO.File]::ReadAllText($dlg.FileName)
        Write-DrvLog "Loaded $([System.IO.Path]::GetFileName($dlg.FileName))"
        Invoke-DrvBuildPreview
    }
    catch { Show-DrvMessage "Could not read the file:`r`n$($_.Exception.Message)" 'Error' }
}

function Invoke-DrvBuildPreview {
    $App = $script:D.App
    $text = $script:D.PasteBox.Text
    $frm = $script:D.Page.FindForm(); if ($frm) { $frm.Cursor = 'WaitCursor' }
    try {
        $App.SetStatus('Reading device data...')
        $p = ConvertFrom-DeviceRegistryText -Text $text
        if ($p.Kind -eq 'Empty') { $App.SetStatus('Paste device registry rows (or load the CSV) first.', 'warn'); return }

        if ($p.Kind -eq 'DriverList') {
            $rows = @(ConvertFrom-RSLinxDriverList -Rows $p.Rows)
            Write-DrvLog "Driver list (Name,Node): $($rows.Count) row(s)."
        }
        else {
            $table = @(Get-VlanLookupTable -App $App)
            $resolver = New-VlanResolver -Entries $table
            $siteMap = New-SiteCodeMap -Entries @(Get-SiteCodeTable -App $App)
            $mfr = Get-DrvManufacturer
            $res = ConvertTo-RSLinxDriverRows -Devices $p.Rows -Resolver $resolver -SiteMap $siteMap -ManufacturerMatch $mfr `
                       -IncludeInactive:($script:D.ChkInactive.Checked) -PrimaryOnly:(-not $script:D.ChkSecondary.Checked)
            $rows = @($res.Rows)
            $s = $res.Stats
            if (-not $p.HeaderFound) { Write-DrvLog 'No header row found - assumed the standard device registry column order.' }
            if (@($p.Missing).Count -gt 0) {
                Write-DrvLog ("Column(s) not found: {0}. Columns in the data: {1}" -f (@($p.Missing) -join ', '), ((@($p.Columns) | Select-Object -First 40) -join ' | ')) 'WARN'
            }
            Write-DrvLog ("Device rows: {0:N0}.  Used: {1:N0} IP(s) in {2:N0} driver(s).  Skipped: {3:N0} not {4}, {5:N0} inactive, {6:N0} no site code, {7:N0} no IP, {8:N0} bad IP, {9:N0} duplicate." -f `
                $s.DeviceRows, $s.IPs, $s.Drivers, $s.NotManufacturer, $mfr, $s.Inactive, $s.BadSite, $s.NoIP, $s.BadIP, $s.Duplicates)
            if (@($res.BadSites).Count -gt 0) {
                Write-DrvLog ("{0:N0} row(s) skipped because their Lease has no site code - add these on the Site Codes tab: {1}" -f `
                    $s.BadSite, ((@($res.BadSites) | Select-Object -First 25) -join ', ')) 'WARN'
            }
            if ($s.DeviceRows -gt 0 -and $s.NotManufacturer -eq $s.DeviceRows) {
                Write-DrvLog "No row has Manufacturer '$mfr' - check the pasted columns (Environment tab: Manufacturer to include)." 'WARN'
            }
            if (@($res.Unmatched).Count -gt 0) {
                Write-DrvLog ("{0} subnet(s) have no VLAN lookup entry and were named SITE(octet)SCADA - add them on the VLAN Lookup tab: {1}" -f `
                    @($res.Unmatched).Count, ((@($res.Unmatched) | Select-Object -First 20) -join ', ') + $(if (@($res.Unmatched).Count -gt 20) { ', ...' } else { '' })) 'WARN'
            }
        }
        Set-DrvPreview -Rows $rows
        $App.SetStatus("Preview: $($rows.Count) row(s).", 'ok')
    }
    catch {
        Write-DrvLog "Build preview failed: $($_.Exception.Message)" 'ERROR'
        $App.SetStatus('Build preview failed - see Activity.', 'err')
    }
    finally { if ($frm) { $frm.Cursor = 'Default' } }
}

# ---------------------------------------------------------------------------
#  2. preview
# ---------------------------------------------------------------------------
function Set-DrvPreview {
    param([object[]]$Rows = @())
    $script:D.Preview.Clear()
    $id = 0
    foreach ($r in $Rows) {
        $id++
        $r | Add-Member -NotePropertyName RowId -NotePropertyValue $id -Force
        [void]$script:D.Preview.Add($r)
    }

    $clb = $script:D.Sites
    $script:D.SitesBusy = $true
    $clb.BeginUpdate()
    try {
        $clb.Items.Clear()
        $sites = @($Rows | ForEach-Object { if ($_.Site) { $_.Site } else { '(none)' } } | Sort-Object -Unique)
        foreach ($s in $sites) {
            $n = @($Rows | Where-Object { ($(if ($_.Site) { $_.Site } else { '(none)' })) -eq $s }).Count
            [void]$clb.Items.Add(('{0}  ({1})' -f $s, $n), $true)
        }
    } finally { $clb.EndUpdate(); $script:D.SitesBusy = $false }
    Invoke-DrvPreviewFilter
}

function Set-DrvAllSites {
    param([bool]$Checked)
    $clb = $script:D.Sites
    $script:D.SitesBusy = $true
    try { for ($i = 0; $i -lt $clb.Items.Count; $i++) { $clb.SetItemChecked($i, $Checked) } }
    finally { $script:D.SitesBusy = $false }
    Invoke-DrvPreviewFilter
}

function Get-DrvCheckedSites {
    $h = @{}
    foreach ($it in $script:D.Sites.CheckedItems) { $h[([string]$it).Split(' ')[0]] = $true }
    return $h
}

function Test-DrvSiteChecked {
    param($Row, [hashtable]$Sites)
    $s = $(if ($Row.Site) { $Row.Site } else { '(none)' })
    return $Sites.ContainsKey($s)
}

function Invoke-DrvPreviewFilter { if ($script:D.PreviewFilter) { & $script:D.PreviewFilter.Apply } }

function Update-DrvPreviewGrid {
    param($Regex)
    $g = $script:D.PreviewGrid
    $sites = Get-DrvCheckedSites
    $inSites = @($script:D.Preview | Where-Object { Test-DrvSiteChecked -Row $_ -Sites $sites })
    $rows = @(Select-FilterMatch -Items $inSites -Regex $Regex -Property 'Driver', 'IP', 'Asset', 'Model', 'Description', 'Site', 'Note', 'Match')
    $script:D.Filling = $true
    $g.SuspendLayout()
    try {
        $g.Rows.Clear()
        foreach ($r in $rows) {
            $i = $g.Rows.Add([bool]$r.Include, $r.Driver, $r.IP, $r.Site, $r.Asset, $r.Source, $r.Model, $r.Description, $r.Match, $r.Note)
            $g.Rows[$i].Tag = $r
            Set-DrvPreviewRowStyle -GridRow $g.Rows[$i]
        }
    }
    finally { $g.ResumeLayout(); $script:D.Filling = $false }
    $script:D.PreviewCount.Text = '{0:N0} shown of {1:N0}' -f $rows.Count, $script:D.Preview.Count
    Update-DrvPreviewSummary
}

function Set-DrvPreviewRowStyle {
    param($GridRow)
    $r = $GridRow.Tag
    if ($r.Note -and $r.Note -notlike 'Also:*') {
        $GridRow.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(253, 226, 226)
        $GridRow.Cells['Note'].Style.ForeColor = [System.Drawing.Color]::Firebrick
    }
    else {
        $GridRow.DefaultCellStyle.BackColor = [System.Drawing.Color]::Empty
        $GridRow.Cells['Note'].Style.ForeColor = [System.Drawing.Color]::Empty
    }
    if ($r.Match -eq 'Default') { $GridRow.Cells['Driver'].Style.BackColor = [System.Drawing.Color]::FromArgb(255, 243, 190) }
    else { $GridRow.Cells['Driver'].Style.BackColor = [System.Drawing.Color]::Empty }
    if (-not $r.Include) { $GridRow.DefaultCellStyle.ForeColor = $script:D.App.Theme.Muted } else { $GridRow.DefaultCellStyle.ForeColor = [System.Drawing.Color]::Empty }
}

function Invoke-DrvPreviewCellChanged {
    param([int]$RowIndex, [int]$ColumnIndex)
    if ($script:D.Filling -or $RowIndex -lt 0) { return }
    $g = $script:D.PreviewGrid
    $gr = $g.Rows[$RowIndex]; $r = $gr.Tag; if (-not $r) { return }
    $name = $g.Columns[$ColumnIndex].Name
    $v = $gr.Cells[$ColumnIndex].Value
    switch ($name) {
        'Include' { $r.Include = [bool]$v }
        'Driver'  { $r.Driver = ([string]$v).Trim(); if ($r.Match -ne 'List') { $r.Match = 'Edited' } }
        'IP'      { $r.IP = ([string]$v).Trim() }
        default   { return }
    }
    $also = $(if ($r.Note -like 'Also:*') { $r.Note } else { '' })
    $why = Test-RSLinxDriverRow -Row $r
    $r.Note = $(if ($why) { $why } else { $also })
    $script:D.Filling = $true
    try {
        if ($name -ne 'Include') { $gr.Cells[$ColumnIndex].Value = $r.$name }
        $gr.Cells['Note'].Value = $r.Note; $gr.Cells['Match'].Value = $r.Match
    } finally { $script:D.Filling = $false }
    Set-DrvPreviewRowStyle -GridRow $gr
    Update-DrvPreviewSummary
}

function Get-DrvApplyRows {
    $sites = Get-DrvCheckedSites
    return @($script:D.Preview | Where-Object {
        $_.Include -and (Test-DrvSiteChecked -Row $_ -Sites $sites) -and -not ($_.Note -and $_.Note -notlike 'Also:*') })
}

function Update-DrvPreviewSummary {
    if (-not $script:D.PreviewSummary) { return }
    $ok = @(Get-DrvApplyRows)
    $drivers = @($ok | ForEach-Object { ([string]$_.Driver).ToUpperInvariant() } | Sort-Object -Unique).Count
    $bad = @($script:D.Preview | Where-Object { $_.Note -and $_.Note -notlike 'Also:*' }).Count
    $skip = @($script:D.Preview | Where-Object { -not $_.Include }).Count
    $txt = 'Ready to apply: {0:N0} driver(s), {1:N0} IP(s)' -f $drivers, $ok.Count
    if ($bad) { $txt += ('     {0:N0} with problems' -f $bad) }
    if ($skip) { $txt += ('     {0:N0} not used' -f $skip) }
    $script:D.PreviewSummary.Text = $txt
    $can = ($ok.Count -gt 0 -and $script:D.IsAdmin)
    $script:D.BtnAdd.Enabled = $can; $script:D.BtnOverwrite.Enabled = $can
}

function Set-DrvSelectedInclude {
    param([bool]$Value)
    $g = $script:D.PreviewGrid
    $script:D.Filling = $true
    try {
        foreach ($gr in @($g.SelectedRows)) { $gr.Tag.Include = $Value; $gr.Cells['Include'].Value = $Value; Set-DrvPreviewRowStyle -GridRow $gr }
    } finally { $script:D.Filling = $false }
    Update-DrvPreviewSummary
}

function Remove-DrvSelectedPreviewRows {
    $ids = @{}
    foreach ($gr in @($script:D.PreviewGrid.SelectedRows)) { if ($gr.Tag) { $ids[[int]$gr.Tag.RowId] = $true } }
    if ($ids.Count -eq 0) { $script:D.App.SetStatus('Select preview rows first.', 'warn'); return }
    $keep = @($script:D.Preview | Where-Object { -not $ids.ContainsKey([int]$_.RowId) })
    $script:D.Preview.Clear()
    foreach ($r in $keep) { [void]$script:D.Preview.Add($r) }
    Write-DrvLog "Removed $($ids.Count) row(s) from the preview."
    Invoke-DrvPreviewFilter
}

function Invoke-DrvApply {
    param([ValidateSet('Add', 'Overwrite')] [string]$Mode)
    $App = $script:D.App
    if (-not $script:D.IsAdmin) { Show-DrvMessage 'Changing drivers needs administrator rights. Use "Restart as administrator".' 'Warning'; return }
    $rows = @(Get-DrvApplyRows)
    if ($rows.Count -eq 0) { $App.SetStatus('Nothing to apply.', 'warn'); return }

    try { $current = @(Get-RSLinxDrivers) } catch { Show-DrvMessage "Cannot read the current drivers:`r`n$($_.Exception.Message)" 'Error'; return }
    $plan = New-RSLinxApplyPlan -Current $current -Entries $rows -Mode $Mode
    $curIPs = ($current | ForEach-Object { @($_.Nodes).Count } | Measure-Object -Sum).Sum
    if (-not $curIPs) { $curIPs = 0 }

    if ($Mode -eq 'Add') {
        if (@($plan.Items).Count -eq 0) { Show-DrvMessage "Nothing to add: all $($plan.SkippedIPs) IP(s) are already on this PC."; return }
        $q = "Add to this PC: {0} new driver(s), {1} existing driver(s) get more IPs, {2} IP(s) added, {3} already present. The current drivers are backed up first." -f `
                $plan.NewDrivers, $plan.ExtendedDrivers, $plan.AddedIPs, $plan.SkippedIPs
        if (-not (Confirm-DrvChange 'Add drivers' $q (Get-RSLinxPlanCommandText -Plan $plan -BackupNote (Get-DrvBackupNote)))) { return }
    }
    else {
        $q = "OVERWRITE this PC: delete all {0} driver(s) ({1} IPs) now on this PC and write {2} driver(s) with {3} IP(s) from the preview. The current drivers are backed up first." -f `
                @($plan.DeleteKeys).Count, $curIPs, $plan.NewDrivers, $plan.AddedIPs
        if (-not (Confirm-DrvChange 'Overwrite drivers' $q (Get-RSLinxPlanCommandText -Plan $plan -BackupNote (Get-DrvBackupNote)))) { return }
    }

    if (-not (Invoke-DrvAutoBackup -Drivers $current -Label "before-$($Mode.ToLower())")) { return }
    try {
        Invoke-RSLinxApplyPlan -Plan $plan
        $msg = $(if ($Mode -eq 'Add') { "Added $($plan.AddedIPs) IP(s): $($plan.NewDrivers) new driver(s), $($plan.ExtendedDrivers) extended, $($plan.SkippedIPs) already present." }
                 else { "Overwrote drivers: removed $(@($plan.DeleteKeys).Count), wrote $($plan.NewDrivers) driver(s) with $($plan.AddedIPs) IP(s)." })
        Write-DrvLog $msg
        foreach ($it in @($plan.Items)) { Write-DrvLog ("  {0,-9} {1,-16} +{2} IP(s){3}" -f $it.Key, $it.Name, $it.Added, $(if ($it.IsNew) { ' (new)' } else { '' })) }
        $App.LogAction("$Mode drivers: $msg")
        Write-DrvLog 'If RSLinx is running, restart it (or the PC) to load the changed drivers.'
        $App.SetStatus($msg, 'ok')
    }
    catch {
        Write-DrvLog "Apply failed: $($_.Exception.Message)" 'ERROR'
        $App.LogAction("$Mode drivers FAILED: $($_.Exception.Message)")
        Show-DrvMessage "Applying the drivers failed:`r`n$($_.Exception.Message)`r`n`r`nThe backup taken just before is in the Backups list." 'Error'
    }
    Update-DrvCurrent
    Update-DrvBackupList
}

# ---------------------------------------------------------------------------
#  3. drivers on this PC
# ---------------------------------------------------------------------------
function Update-DrvCurrent {
    try {
        $script:D.Current = @(Get-RSLinxDrivers)
        $script:D.CurrentRows = @(foreach ($d in $script:D.Current) {
            if (@($d.Nodes).Count -eq 0) { [pscustomobject]@{ Driver = $d.Name; IP = ''; Key = $d.Key } }
            foreach ($ip in @($d.Nodes)) { [pscustomobject]@{ Driver = $d.Name; IP = $ip; Key = $d.Key } }
        })
        Write-DrvLog ("This PC: {0} driver(s), {1} IP(s)." -f $script:D.Current.Count, @($script:D.CurrentRows | Where-Object { $_.IP }).Count)
    }
    catch {
        $script:D.Current = @(); $script:D.CurrentRows = @()
        Write-DrvLog "Cannot read RSLinx drivers: $($_.Exception.Message)" 'ERROR'
    }
    if ($script:D.CurrentFilter) { & $script:D.CurrentFilter.Apply }
}

function Update-DrvCurrentGrid {
    param($Regex)
    $g = $script:D.CurrentGrid
    $rows = @(Select-FilterMatch -Items $script:D.CurrentRows -Regex $Regex -Property 'Driver', 'IP', 'Key')
    $g.SuspendLayout()
    try {
        $g.Rows.Clear()
        foreach ($r in $rows) { $i = $g.Rows.Add($r.Driver, $r.IP, $r.Key); $g.Rows[$i].Tag = $r }
    } finally { $g.ResumeLayout() }
    $script:D.CurrentCount.Text = '{0:N0} shown of {1:N0}' -f $rows.Count, $script:D.CurrentRows.Count
}

function Invoke-DrvRemoveSelected {
    $App = $script:D.App
    if (-not $script:D.IsAdmin) { return }
    $sel = @($script:D.CurrentGrid.SelectedRows | ForEach-Object { $_.Tag } | Where-Object { $_ })
    if ($sel.Count -eq 0) { $App.SetStatus('Select drivers / IPs on the right first.', 'warn'); return }
    $q = "Remove {0} IP(s) from {1} driver(s) on this PC. A driver left with no IPs is deleted. The current drivers are backed up first." -f `
            $sel.Count, @($sel | ForEach-Object { $_.Key } | Sort-Object -Unique).Count
    $targets0 = @($sel | ForEach-Object { [pscustomobject]@{ Key = $_.Key; IP = $_.IP } })
    if (-not (Confirm-DrvChange 'Remove drivers' $q (Get-RSLinxRemoveCommandText -Targets $targets0 -Current $script:D.Current -BackupNote (Get-DrvBackupNote)))) { return }
    if (-not (Invoke-DrvAutoBackup -Drivers $script:D.Current -Label 'before-remove')) { return }
    try {
        $targets = @($sel | ForEach-Object { [pscustomobject]@{ Key = $_.Key; IP = $_.IP } })
        $r = Remove-RSLinxDriverNodes -Targets $targets
        $msg = "Removed $($r.RemovedIPs) IP(s); $($r.RemovedDrivers) driver(s) deleted."
        Write-DrvLog $msg
        foreach ($s in $sel) { Write-DrvLog ("  - {0} {1}" -f $s.Driver, $s.IP) }
        $App.LogAction("Remove drivers: $msg " + (($sel | ForEach-Object { "$($_.Driver)=$($_.IP)" }) -join ', '))
        $App.SetStatus($msg, 'ok')
    }
    catch { Write-DrvLog "Remove failed: $($_.Exception.Message)" 'ERROR'; Show-DrvMessage "Remove failed:`r`n$($_.Exception.Message)" 'Error' }
    Update-DrvCurrent
    Update-DrvBackupList
}

function Copy-DrvCurrentToPreview {
    $sel = @($script:D.CurrentGrid.SelectedRows | ForEach-Object { $_.Tag } | Where-Object { $_ -and $_.IP })
    if ($sel.Count -eq 0) { $sel = @($script:D.CurrentRows | Where-Object { $_.IP }) }
    if ($sel.Count -eq 0) { return }
    $rows = @(ConvertFrom-RSLinxDriverList -Rows @($sel | ForEach-Object { @{ name = $_.Driver; node = $_.IP } }))
    if ($script:D.Preview.Count -gt 0 -and (Show-DrvQuestion "Replace the $($script:D.Preview.Count) preview row(s) with $($rows.Count) row(s) from this PC?") -ne 'Yes') { return }   # preview only
    Set-DrvPreview -Rows $rows
    Write-DrvLog "Copied $($rows.Count) row(s) from this PC to the preview."
}

# ---------------------------------------------------------------------------
#  backups
# ---------------------------------------------------------------------------
function Invoke-DrvAutoBackup {
    param([object[]]$Drivers = @(), [string]$Label = 'auto')
    if (@($Drivers).Count -eq 0) { return $true }
    try {
        $p = Save-RSLinxBackup -App $script:D.App -Drivers $Drivers -Name $Label
        Write-DrvLog "Backup saved: $p"
        return $true
    }
    catch {
        Write-DrvLog "Backup failed: $($_.Exception.Message)" 'ERROR'
        Show-DrvMessage "Could not back up the current drivers, so nothing was changed:`r`n$($_.Exception.Message)" 'Error'
        return $false
    }
}

function Update-DrvBackupList {
    param([switch]$Refresh)
    try {
        $b = Get-RSLinxBackupDir -App $script:D.App -Refresh:$Refresh
        $script:D.BackupDir = $b.Path
        $script:D.BackupDirLabel.Text = $(if ($b.IsFallback) { "Folder: $($b.Path)`r`n(local - $($b.Reason))" } else { "Folder: $($b.Path)" })
        $script:D.Backups = @(Get-RSLinxBackupFiles -Path $b.Path)
    }
    catch {
        $script:D.Backups = @()
        $script:D.BackupDirLabel.Text = "Backups unavailable: $($_.Exception.Message)"
    }
    if ($script:D.BackupFilter) { & $script:D.BackupFilter.Apply }
}

function Update-DrvBackupListBox {
    param($Regex)
    $list = $script:D.BackupList
    $items = @(Select-FilterMatch -Items $script:D.Backups -Regex $Regex -Property 'Name')
    $list.BeginUpdate()
    try {
        $list.Items.Clear()
        foreach ($f in $items) { [void]$list.Items.Add(('{0}   {1}' -f $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm'), $f.Name)) }
    } finally { $list.EndUpdate() }
    $script:D.BackupShown = $items
    $script:D.BackupCount.Text = '{0} of {1}' -f $items.Count, $script:D.Backups.Count
}

function Get-DrvSelectedBackup {
    $i = $script:D.BackupList.SelectedIndex
    if ($i -lt 0 -or -not $script:D.BackupShown -or $i -ge @($script:D.BackupShown).Count) { return $null }
    return @($script:D.BackupShown)[$i]
}

function Invoke-DrvSaveBackup {
    $App = $script:D.App
    Update-DrvCurrent
    if ($script:D.Current.Count -eq 0) { Show-DrvMessage 'There are no drivers on this PC to back up.'; return }
    Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction SilentlyContinue
    $name = [Microsoft.VisualBasic.Interaction]::InputBox("Optional name for this backup (the computer name and date are added):", 'Save current drivers', '')
    try {
        $p = Save-RSLinxBackup -App $App -Drivers $script:D.Current -Name $name
        Write-DrvLog "Backup saved: $p"
        $App.LogAction("Backup saved: $p")
        $App.SetStatus('Backup saved.', 'ok')
    }
    catch { Write-DrvLog "Backup failed: $($_.Exception.Message)" 'ERROR'; Show-DrvMessage "Backup failed:`r`n$($_.Exception.Message)" 'Error' }
    Update-DrvBackupList
}

function Invoke-DrvRestoreBackup {
    $f = Get-DrvSelectedBackup
    if (-not $f) { $script:D.App.SetStatus('Select a backup first.', 'warn'); return }
    try {
        $rows = @(ConvertFrom-RSLinxDriverList -Rows (Read-RSLinxBackup -Path $f.FullName))
        if ($script:D.Preview.Count -gt 0 -and (Show-DrvQuestion "Replace the $($script:D.Preview.Count) preview row(s) with $($rows.Count) row(s) from $($f.Name)?") -ne 'Yes') { return }
        Set-DrvPreview -Rows $rows
        Write-DrvLog "Restored $($f.Name) to the preview ($($rows.Count) row(s)). Use Add or Overwrite to put it on this PC."
    }
    catch { Show-DrvMessage $_.Exception.Message 'Error' }
}

function Remove-DrvBackup {
    $f = Get-DrvSelectedBackup
    if (-not $f) { $script:D.App.SetStatus('Select a backup first.', 'warn'); return }
    $r = Invoke-AppCommand -App $script:D.App -Title 'Delete backup' -Kind Change -RunLabel 'Delete' -Summary "Delete the backup file $($f.Name)." `
        -Code ('Remove-Item -LiteralPath ' + (Format-AppCommandValue $f.FullName) + ' -Force -ErrorAction Stop')
    if (-not $r.Ran) { return }
    if ($r.Errors.Count) { Show-DrvMessage "Delete failed:`r`n$($r.Errors[0])" 'Error' }
    else {
        Write-DrvLog "Deleted backup $($f.Name)"
        $script:D.App.LogAction("Deleted backup $($f.FullName)")
    }
    Update-DrvBackupList
}
