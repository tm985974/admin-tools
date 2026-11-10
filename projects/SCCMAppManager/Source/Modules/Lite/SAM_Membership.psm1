# SAM_Membership.psm1   (LITE TIER)
#
# Adding devices to collections (direct membership rules):
#   Select-SamDeviceCollection        picker of collections that can take direct members
#   Invoke-SamAddDevicesToCollection  Devices tab: selected devices -> one collection
#   Invoke-SamAddDevicesByName        Collections tab: pick from a list / paste / load a file
#   Show-SamAddDevicesDialog          the pick / paste dialog (ported from v8.4)
# Removing members is admin tier (Modules\Admin\SAM_AdminActions.psm1).

$global:SamAppStatusText = @{ 1 = 'Success'; 2 = 'In progress'; 3 = 'Requirements not met'; 4 = 'Unknown'; 5 = 'Error' }
$global:SamStatusColors = @{
    'Success'              = [System.Drawing.Color]::FromArgb(214, 240, 214)
    'Error'                = [System.Drawing.Color]::FromArgb(255, 210, 210)
    'In progress'          = [System.Drawing.Color]::FromArgb(214, 230, 250)
    'Requirements not met' = [System.Drawing.Color]::FromArgb(255, 243, 176)
}

# Built-in collections (SMS...) and user collections cannot take device rules.
function Test-SamEditableDeviceCollection {
    param($Collection, [switch]$Quiet)
    if (-not $Collection) { return $false }
    $why = ''
    if ($Collection.Type -ne 'Device') { $why = "'$($Collection.Name)' is a user collection." }
    elseif ($Collection.BuiltIn) { $why = "'$($Collection.Name)' ($($Collection.ID)) is a built-in collection and cannot be changed." }
    if ($why) { if (-not $Quiet) { Write-SamLog $why -Level Warning }; return $false }
    return $true
}

function Select-SamDeviceCollection {
    param([string]$Title = 'Add to collection', [string]$Prompt = 'Device collection')
    $items = @($global:SAM.Cache.Collections.ToArray() | Where-Object { Test-SamEditableDeviceCollection $_ -Quiet })
    $pick = Show-SamListPicker -Title $Title -Prompt $Prompt -OkText 'Select' -Items $items -Columns @(
        @{ Name = 'Name'; Header = 'Collection'; Fill = 60 },
        @{ Name = 'ID'; Width = 90 },
        @{ Name = 'Members'; Type = 'int'; Width = 75 },
        @{ Name = 'AppDeploys'; Header = 'App deploys'; Type = 'int'; Width = 85 },
        @{ Name = 'Limiting'; Header = 'Limiting collection'; Fill = 30 },
        @{ Name = 'Folder'; Fill = 25 })
    if (-not $pick) { return $null }
    return @($pick)[0]
}

function Assert-SamDeviceCache {
    if (-not $global:SAM.DeviceCache) { Update-SamDeviceCache }
    return [bool]$global:SAM.DeviceCache
}

# Devices = device objects from the device cache (ResourceID, Name, IsClient, IsObsolete).
function Invoke-SamAddDevicesToCollection {
    param($Devices, $Collection = $null)
    $S = $global:SAM
    $devs = @(@($Devices) | Where-Object { $_ })
    if (-not $devs.Count) { Write-SamLog 'Select one or more devices first.' -Level Warning; return }
    if (-not $Collection) { $Collection = Select-SamDeviceCollection -Title "Add $($devs.Count) device(s) to collection" }
    if (-not $Collection) { return }
    if (-not (Test-SamEditableDeviceCollection $Collection)) { return }
    [void](Assert-SamDeviceCache)

    $toAdd = New-Object System.Collections.ArrayList
    $already = New-Object System.Collections.ArrayList
    $obsolete = New-Object System.Collections.ArrayList
    $noClient = New-Object System.Collections.ArrayList
    foreach ($d in $devs) {
        $direct = $S.DeviceCache.Direct[[int]$d.ResourceID]
        if ($direct -and $direct.ContainsKey($Collection.ID)) { [void]$already.Add($d.Name); continue }
        if ($d.IsObsolete) { [void]$obsolete.Add($d.Name); continue }
        if (-not $d.IsClient) { [void]$noClient.Add($d.Name) }
        [void]$toAdd.Add($d)
    }
    if ($already.Count)  { Write-SamLog "  Already direct members ($($already.Count)): $($already.ToArray() -join ', ')" }
    if ($obsolete.Count) { Write-SamLog "  Obsolete records, skipped ($($obsolete.Count)): $($obsolete.ToArray() -join ', ')" -Level Warning }
    if ($noClient.Count) { Write-SamLog "  No SCCM client - added, but nothing will install ($($noClient.Count)): $($noClient.ToArray() -join ', ')" -Level Warning }
    if (-not $toAdd.Count) { Write-SamLog 'Nothing to add.' -Level Warning; return }

    $intro = "Add $($toAdd.Count) device(s) to '$($Collection.Name)' ($($Collection.ID))?"
    if ($already.Count -or $obsolete.Count) { $intro += "`r`n($($already.Count) already members, $($obsolete.Count) obsolete - skipped)" }
    if ($noClient.Count) { $intro += "`r`n$($noClient.Count) of them have no SCCM client." }
    $code = Get-SamCmCode -Note 'The app adds the direct rules through the SMS Provider (AddMembershipRules) and falls back to this cmdlet; then it asks the site to update the collection.' -Lines @(
        'Add-CMDeviceCollectionDirectMembershipRule -CollectionId ' + (Format-SamCode ([string]$Collection.ID)) + ' -ResourceId ' + (Format-SamCode ([int[]]@($toAdd.ToArray() | ForEach-Object { [int]$_.ResourceID }))),
        'Invoke-CMCollectionUpdate -CollectionId ' + (Format-SamCode ([string]$Collection.ID)))
    if (-not (Confirm-SamBatch 'Add to collection' $intro @($toAdd.ToArray() | ForEach-Object { $_.Name }) -Code $code)) { return }
    Add-SamMembersAndRefresh -Collection $Collection -Devices $toAdd.ToArray()
}

function Add-SamMembersAndRefresh {
    param($Collection, $Devices)
    $S = $global:SAM
    $list = @($Devices)
    $added = Measure-SamStep "Add $($list.Count) direct rule(s) to '$($Collection.Name)'" { Add-SamDirectMembers -CollectionID $Collection.ID -Devices $list }
    Write-SamLog "Added $added of $($list.Count) device(s) to '$($Collection.Name)'" -Level Success
    try { $S.App.LogAction("Added $added device(s) to collection '$($Collection.Name)' ($($Collection.ID)): $((@($list) | ForEach-Object { $_.Name }) -join ', ')") } catch { }
    [void](Request-SamCollectionRefresh -CollectionID $Collection.ID)
    # Direct members usually appear within seconds of the refresh request
    for ($i = 0; $i -lt 6; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 500 }
    Update-SamCollectionMembership -CollectionID $Collection.ID
    Invoke-SamRenderViews
}

# Collections tab: pick / paste device names for one collection.
function Invoke-SamAddDevicesByName {
    param($Collection)
    $S = $global:SAM
    if (-not (Test-SamEditableDeviceCollection $Collection)) { return }
    [void](Assert-SamDeviceCache)
    $current = @{}
    $q = 'SELECT ResourceID FROM SMS_FullCollectionMembership WHERE CollectionID = {0}' -f (ConvertTo-SamWql $Collection.ID)
    foreach ($m in @(Measure-SamStep "Current members of '$($Collection.Name)'" { Get-SamSmsData $q })) { $current[[int]$m.ResourceID] = $true }

    $names = @(Show-SamAddDevicesDialog -CollectionName $Collection.Name -CurrentMembers $current)
    if (-not $names.Count) { Write-SamLog 'Add devices cancelled (nothing selected).'; return }

    $toAdd = New-Object System.Collections.ArrayList
    $notFound = New-Object System.Collections.ArrayList
    $already = New-Object System.Collections.ArrayList
    $obsolete = New-Object System.Collections.ArrayList
    $noClient = New-Object System.Collections.ArrayList
    $missing = New-Object System.Collections.ArrayList
    foreach ($n in $names) { if (-not $S.DeviceCache.ByName.ContainsKey($n)) { [void]$missing.Add($n) } }
    # Names not in the cache: look them up live (new devices), 40 per query
    $live = @{}
    for ($i = 0; $i -lt $missing.Count; $i += 40) {
        $chunk = $missing.GetRange($i, [Math]::Min(40, $missing.Count - $i)).ToArray()
        $where = ($chunk | ForEach-Object { 'Name = ' + (ConvertTo-SamWql $_) }) -join ' OR '
        foreach ($r in @(Get-SamSmsData "SELECT ResourceId, Name, Client, Obsolete FROM SMS_R_System WHERE $where")) {
            $nm = ([string]$r.Name).ToUpper()
            $o = [pscustomobject]@{ ResourceID = [int]$r.ResourceId; Name = $nm; IsClient = [bool]$r.Client; IsObsolete = [bool]$r.Obsolete }
            if (-not $live.ContainsKey($nm) -or (-not $o.IsObsolete -and $live[$nm].IsObsolete)) { $live[$nm] = $o }
        }
    }
    foreach ($n in $names) {
        $d = $S.DeviceCache.ByName[$n]
        if (-not $d) { $d = $live[$n] }
        if (-not $d)                          { [void]$notFound.Add($n); continue }
        if ($d.IsObsolete)                    { [void]$obsolete.Add($n); continue }
        if ($current[[int]$d.ResourceID])     { [void]$already.Add($n); continue }
        if (-not $d.IsClient)                 { [void]$noClient.Add($n) }
        [void]$toAdd.Add($d)
    }
    if ($notFound.Count) { Write-SamLog "  Not found in SCCM ($($notFound.Count)): $($notFound.ToArray() -join ', ')" -Level Warning }
    if ($obsolete.Count) { Write-SamLog "  Obsolete records, skipped ($($obsolete.Count)): $($obsolete.ToArray() -join ', ')" -Level Warning }
    if ($already.Count)  { Write-SamLog "  Already members ($($already.Count)): $($already.ToArray() -join ', ')" }
    if ($noClient.Count) { Write-SamLog "  No SCCM client - added, but nothing will install ($($noClient.Count)): $($noClient.ToArray() -join ', ')" -Level Warning }
    if (-not $toAdd.Count) { Write-SamLog 'Nothing to add.' -Level Warning; return }

    $intro = "Add $($toAdd.Count) device(s) to '$($Collection.Name)'?"
    $skipped = $notFound.Count + $obsolete.Count + $already.Count
    if ($skipped) { $intro += "`r`n($($notFound.Count) not found, $($obsolete.Count) obsolete, $($already.Count) already members - see the activity log)" }
    if ($noClient.Count) { $intro += "`r`n$($noClient.Count) of them have no SCCM client." }
    $code = Get-SamCmCode -Note 'The app adds the direct rules through the SMS Provider (AddMembershipRules) and falls back to this cmdlet; then it asks the site to update the collection.' -Lines @(
        'Add-CMDeviceCollectionDirectMembershipRule -CollectionId ' + (Format-SamCode ([string]$Collection.ID)) + ' -ResourceId ' + (Format-SamCode ([int[]]@($toAdd.ToArray() | ForEach-Object { [int]$_.ResourceID }))),
        'Invoke-CMCollectionUpdate -CollectionId ' + (Format-SamCode ([string]$Collection.ID)))
    if (-not (Confirm-SamBatch 'Add Devices' $intro @($toAdd.ToArray() | ForEach-Object { $_.Name }) -Code $code)) { return }
    Add-SamMembersAndRefresh -Collection $Collection -Devices $toAdd.ToArray()
}

# Returns the chosen device names (checked in the list + pasted / loaded), or $null.
function Show-SamAddDevicesDialog {
    param([string]$CollectionName, [hashtable]$CurrentMembers)
    $all = $global:SAM.DeviceCache.Devices

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Add Devices to '$CollectionName'"
    $dlg.Size = New-Object System.Drawing.Size(980, 720)
    $dlg.StartPosition = 'CenterParent'
    $dlg.MinimizeBox = $false
    $dlg.ShowInTaskbar = $false

    $st = @{ Suppress = $false; Checked = @{} }

    $tabsAdd = New-Object System.Windows.Forms.TabControl
    $tabsAdd.Location = New-Object System.Drawing.Point(10, 10); $tabsAdd.Size = New-Object System.Drawing.Size(945, 600)
    $tabsAdd.Anchor = 'Top,Bottom,Left,Right'
    $dlg.Controls.Add($tabsAdd)

    # ---------- Tab: pick from list ----------
    $tPick = New-Object System.Windows.Forms.TabPage
    $tPick.Text = 'Pick from list'
    [void]$tabsAdd.TabPages.Add($tPick)

    $lf = New-Object System.Windows.Forms.Label
    $lf.Text = 'Filter:'; $lf.Location = New-Object System.Drawing.Point(8, 12); $lf.AutoSize = $true
    $txtF = New-Object System.Windows.Forms.TextBox
    $txtF.Location = New-Object System.Drawing.Point(52, 9); $txtF.Width = 240
    $chkHide = New-Object System.Windows.Forms.CheckBox
    $chkHide.Text = 'Hide current members'; $chkHide.Checked = $false
    $chkHide.Location = New-Object System.Drawing.Point(310, 9); $chkHide.AutoSize = $true
    $btnAll = New-Object System.Windows.Forms.Button
    $btnAll.Text = 'Check all shown'; $btnAll.Location = New-Object System.Drawing.Point(640, 6); $btnAll.Size = New-Object System.Drawing.Size(120, 27)
    $btnNone = New-Object System.Windows.Forms.Button
    $btnNone.Text = 'Clear checks'; $btnNone.Location = New-Object System.Drawing.Point(765, 6); $btnNone.Size = New-Object System.Drawing.Size(100, 27)
    foreach ($c in @($lf, $txtF, $chkHide, $btnAll, $btnNone)) { $tPick.Controls.Add($c) }

    $lv = New-Object System.Windows.Forms.ListView
    $lv.Location = New-Object System.Drawing.Point(8, 40); $lv.Size = New-Object System.Drawing.Size(920, 500)
    $lv.Anchor = 'Top,Bottom,Left,Right'
    $lv.View = 'Details'; $lv.CheckBoxes = $true; $lv.FullRowSelect = $true; $lv.GridLines = $true; $lv.HideSelection = $false
    foreach ($c in @(@('Device', 190), @('Client', 55), @('Active', 55), @('Operating system', 300), @('Last logon user', 160), @('Member', 70))) { [void]$lv.Columns.Add($c[0], $c[1]) }
    $tPick.Controls.Add($lv)

    $lblShown = New-Object System.Windows.Forms.Label
    $lblShown.Location = New-Object System.Drawing.Point(8, 545); $lblShown.Size = New-Object System.Drawing.Size(920, 20)
    $lblShown.Anchor = 'Bottom,Left,Right'
    $tPick.Controls.Add($lblShown)

    # ---------- Tab: paste / file ----------
    $tPaste = New-Object System.Windows.Forms.TabPage
    $tPaste.Text = 'Paste / load from file'
    [void]$tabsAdd.TabPages.Add($tPaste)

    $lp = New-Object System.Windows.Forms.Label
    $lp.Location = New-Object System.Drawing.Point(8, 8); $lp.Size = New-Object System.Drawing.Size(920, 20)
    $lp.Text = 'Device names: one per line, or separated by commas / spaces. FQDN and DOMAIN\ prefixes are fine.'
    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Location = New-Object System.Drawing.Point(8, 32); $txt.Size = New-Object System.Drawing.Size(920, 490)
    $txt.Anchor = 'Top,Bottom,Left,Right'
    $txt.Multiline = $true; $txt.ScrollBars = 'Vertical'; $txt.AcceptsReturn = $true
    $txt.Font = New-Object System.Drawing.Font('Consolas', 9.5)
    $btnFile = New-Object System.Windows.Forms.Button
    $btnFile.Text = 'Load from file...'; $btnFile.Size = New-Object System.Drawing.Size(130, 30)
    $btnFile.Location = New-Object System.Drawing.Point(8, 530); $btnFile.Anchor = 'Bottom,Left'
    foreach ($c in @($lp, $txt, $btnFile)) { $tPaste.Controls.Add($c) }

    # ---------- Bottom ----------
    $lblTotal = New-Object System.Windows.Forms.Label
    $lblTotal.Location = New-Object System.Drawing.Point(12, 627); $lblTotal.Size = New-Object System.Drawing.Size(600, 20)
    $lblTotal.Anchor = 'Bottom,Left'; $lblTotal.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = 'Check && Add...'; $btnOk.Size = New-Object System.Drawing.Size(130, 32)
    $btnOk.Location = New-Object System.Drawing.Point(685, 620); $btnOk.Anchor = 'Bottom,Right'
    $btnOk.BackColor = [System.Drawing.Color]::LightGreen
    $btnOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = 'Cancel'; $btnCancel.Size = New-Object System.Drawing.Size(130, 32)
    $btnCancel.Location = New-Object System.Drawing.Point(825, 620); $btnCancel.Anchor = 'Bottom,Right'
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    foreach ($c in @($lblTotal, $btnOk, $btnCancel)) { $dlg.Controls.Add($c) }
    $dlg.CancelButton = $btnCancel

    $maxShown = 5000
    $getPasted = { @(ConvertTo-SamDeviceNames $txt.Text) }.GetNewClosure()
    $updTotal = {
        $pasted = & $getPasted
        $union = @{}
        foreach ($k in $st.Checked.Keys) { $union[$k] = $true }
        foreach ($p in $pasted) { $union[$p] = $true }
        $lblTotal.Text = "$($union.Count) device(s) selected   ($($st.Checked.Count) checked in list, $($pasted.Count) pasted)"
        $btnOk.Enabled = ($union.Count -gt 0)
    }.GetNewClosure()
    $fill = {
        $rx = New-SamNameMatcher $txtF.Text
        $items = New-Object System.Collections.ArrayList
        $matched = 0
        foreach ($d in $all) {
            if ($d.IsObsolete) { continue }
            $isMember = [bool]$CurrentMembers[$d.ResourceID]
            if ($chkHide.Checked -and $isMember) { continue }
            if ($rx -and -not $rx.IsMatch($d.Name)) { continue }
            $matched++
            if ($items.Count -ge $maxShown) { continue }
            $it = New-Object System.Windows.Forms.ListViewItem($d.Name)
            [void]$it.SubItems.Add($d.Client)
            [void]$it.SubItems.Add($d.Active)
            [void]$it.SubItems.Add($d.OS)
            [void]$it.SubItems.Add($d.LastUser)
            [void]$it.SubItems.Add($(if ($isMember) { 'Yes' } else { '' }))
            if ($isMember -or -not $d.IsClient) { $it.ForeColor = [System.Drawing.Color]::Gray }
            $it.Checked = $st.Checked.ContainsKey($d.Name)
            $it.Tag = $d
            [void]$items.Add($it)
        }
        $st.Suppress = $true
        $lv.BeginUpdate(); $lv.Items.Clear()
        if ($items.Count) { $lv.Items.AddRange([System.Windows.Forms.ListViewItem[]]$items.ToArray()) }
        $lv.EndUpdate()
        $st.Suppress = $false
        $lblShown.Text = if ($matched -gt $maxShown) { "Showing first $maxShown of $matched matching devices - type in Filter to narrow down" }
                         else { "Showing $matched of $($all.Count) devices (filter: device name, * and ? wildcards; grey = already a member or no client)" }
    }.GetNewClosure()

    $lv.Add_ItemChecked({ param($s, $e)
        if ($st.Suppress) { return }
        $n = $e.Item.Text
        if ($e.Item.Checked) { $st.Checked[$n] = $true } else { [void]$st.Checked.Remove($n) }
        & $updTotal
    }.GetNewClosure())
    $btnAll.Add_Click({
        $st.Suppress = $true
        foreach ($it in $lv.Items) { $it.Checked = $true; $st.Checked[$it.Text] = $true }
        $st.Suppress = $false
        & $updTotal
    }.GetNewClosure())
    $btnNone.Add_Click({
        $st.Suppress = $true
        foreach ($it in $lv.Items) { $it.Checked = $false }
        $st.Checked.Clear()
        $st.Suppress = $false
        & $updTotal
    }.GetNewClosure())
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 250
    $timer.Add_Tick({ $timer.Stop(); & $fill }.GetNewClosure())
    $txtF.Add_TextChanged({ $timer.Stop(); $timer.Start() }.GetNewClosure())
    $chkHide.Add_CheckedChanged({ & $fill }.GetNewClosure())
    $txt.Add_TextChanged({ & $updTotal }.GetNewClosure())
    $btnFile.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = 'Text or CSV (*.txt;*.csv)|*.txt;*.csv|All files (*.*)|*.*'
        if ($ofd.ShowDialog($dlg) -eq [System.Windows.Forms.DialogResult]::OK) {
            try {
                $content = [IO.File]::ReadAllText($ofd.FileName)
                $txt.Text = if ($txt.Text.Trim()) { $txt.Text.TrimEnd() + "`r`n" + $content } else { $content }
            } catch { [void][System.Windows.Forms.MessageBox]::Show($dlg, $_.Exception.Message, 'Load file', 'OK', 'Error') }
        }
    }.GetNewClosure())

    & $fill
    & $updTotal
    try {
        if ($dlg.ShowDialog((Get-SamOwnerForm)) -ne [System.Windows.Forms.DialogResult]::OK) { return @() }
        $union = New-Object System.Collections.ArrayList
        $seen = @{}
        foreach ($n in $st.Checked.Keys) { if ($n -and -not $seen.ContainsKey($n)) { $seen[$n] = $true; [void]$union.Add([string]$n) } }
        foreach ($n in (& $getPasted))  { if ($n -and -not $seen.ContainsKey($n)) { $seen[$n] = $true; [void]$union.Add([string]$n) } }
        return $union.ToArray()
    }
    finally { $timer.Dispose(); $dlg.Dispose() }
}
