# SAM_AdminActions.psm1   (ADMIN TIER)
#
# Destructive / structural actions. This module only loads with the admin
# password (or in the developer build); the right-click menus and buttons that
# use these functions appear only when they exist (Get-Command).
#
#   Invoke-SamRemoveDevicesFromCollection      direct members out of a collection
#   Invoke-SamRemoveDevicesFromCollectionPick  Devices tab: pick one of their direct collections
#   Invoke-SamRemoveDeployments                application deployments
#   Invoke-SamSetAppRetired                    retire / reinstate applications
#   Invoke-SamRemoveApplications               delete applications without deployments
#   Invoke-SamRemoveDeviceRecords              delete device records
#   Invoke-SamClearPxe                         clear required PXE deployments
#   New-SamDeviceCollection / Rename-SamCollection / Remove-SamCollections

function Invoke-SamRemoveDevicesFromCollection {
    param($Collection, $Devices)
    $S = $global:SAM
    if (-not (Test-SamEditableDeviceCollection $Collection)) { return }
    [void](Assert-SamDeviceCache)
    $direct = New-Object System.Collections.ArrayList
    $query = New-Object System.Collections.ArrayList
    foreach ($d in @($Devices)) {
        if (-not $d) { continue }
        $isDirect = $false
        if ($d.PSObject.Properties['Membership']) { $isDirect = ($d.Membership -eq 'Direct') }
        else { $h = $S.DeviceCache.Direct[[int]$d.ResourceID]; $isDirect = [bool]($h -and $h.ContainsKey($Collection.ID)) }
        if ($isDirect) { [void]$direct.Add($d) } else { [void]$query.Add($d.Name) }
    }
    if ($query.Count) { Write-SamLog "  Skipping $($query.Count) device(s) that are not direct members (change the collection query to remove them): $($query.ToArray() -join ', ')" -Level Warning }
    if (-not $direct.Count) { Write-SamLog 'Nothing to remove.' -Level Warning; return }
    if (-not (Confirm-SamBatch 'Remove from collection' "Remove these $($direct.Count) direct member(s) from '$($Collection.Name)' ($($Collection.ID))?" @($direct.ToArray() | ForEach-Object { $_.Name }))) { return }

    $removed = Measure-SamStep "Remove $($direct.Count) direct rule(s) from '$($Collection.Name)'" { Remove-SamDirectMembers -CollectionID $Collection.ID -Devices $direct.ToArray() }
    Write-SamLog "Removed $removed of $($direct.Count) device(s) from '$($Collection.Name)'" -Level Success
    try { $S.App.LogAction("Removed $removed device(s) from collection '$($Collection.Name)' ($($Collection.ID)): $((@($direct.ToArray()) | ForEach-Object { $_.Name }) -join ', ')") } catch { }
    [void](Request-SamCollectionRefresh -CollectionID $Collection.ID)
    for ($i = 0; $i -lt 6; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 500 }
    Update-SamCollectionMembership -CollectionID $Collection.ID
    Invoke-SamRenderViews
}

function Invoke-SamRemoveDevicesFromCollectionPick {
    param($Devices)
    $S = $global:SAM
    [void](Assert-SamDeviceCache)
    $devs = @(@($Devices) | Where-Object { $_ })
    $ids = @{}
    foreach ($d in $devs) {
        $h = $S.DeviceCache.Direct[[int]$d.ResourceID]
        if ($h) { foreach ($k in $h.Keys) { $ids[$k] = 1 + [int]$ids[$k] } }
    }
    $items = @($ids.Keys | ForEach-Object { $S.Cache.CollectionsById[$_] } | Where-Object { $_ -and (Test-SamEditableDeviceCollection $_ -Quiet) } | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; ID = $_.ID; Selected = $ids[$_.ID]; Members = $_.Members; Collection = $_ } })
    if (-not $items.Count) { Write-SamLog 'The selected device(s) are not direct members of any editable collection.' -Level Warning; return }
    $pick = Show-SamListPicker -Title 'Remove from collection' -Prompt "Direct collections of the $($devs.Count) selected device(s)" -OkText 'Remove...' -Items $items -Columns @(
        @{ Name = 'Name'; Header = 'Collection'; Fill = 60 },
        @{ Name = 'ID'; Width = 90 },
        @{ Name = 'Selected'; Header = 'Selected devices in it'; Type = 'int'; Width = 140 },
        @{ Name = 'Members'; Type = 'int'; Width = 75 })
    if (-not $pick) { return }
    Invoke-SamRemoveDevicesFromCollection -Collection (@($pick)[0]).Collection -Devices $devs
}

# Deployments = rows with AssignmentID, Application, Collection.
function Invoke-SamRemoveDeployments {
    param($Deployments)
    $S = $global:SAM
    $list = @(@($Deployments) | Where-Object { $_ -and $_.AssignmentID })
    if (-not $list.Count) { Write-SamLog 'Only application deployments can be deleted here.' -Level Warning; return }
    if (-not (Confirm-SamBatch 'Delete deployments' "Delete these $($list.Count) application deployment(s)?" @($list | ForEach-Object { "$($_.Application)  ->  $($_.Collection)" }))) { return }
    $ok = 0
    foreach ($d in $list) {
        try {
            $a = Get-SamSmsData ('SELECT * FROM SMS_ApplicationAssignment WHERE AssignmentID = {0}' -f [int]$d.AssignmentID) | Select-Object -First 1
            if (-not $a) { throw 'deployment not found' }
            Remove-CimInstance -InputObject $a -ErrorAction Stop
            $ok++
        }
        catch {
            Write-SamLog "  WMI delete not accepted ($($_.Exception.Message)) - using the ConfigMgr cmdlet" -Level Warning
            try { Invoke-SamCM { Remove-CMApplicationDeployment -Name $d.Application -CollectionName $d.Collection -Force -ErrorAction Stop }; $ok++ }
            catch { Write-SamLog "  $($d.Application) -> $($d.Collection): $($_.Exception.Message)" -Level Error; continue }
        }
        Write-SamLog "  Deleted: $($d.Application) -> $($d.Collection)" -Level Success
        try { $S.App.LogAction("Deleted deployment '$($d.Application)' -> '$($d.Collection)'") } catch { }
    }
    Write-SamLog "Deleted $ok of $($list.Count) deployment(s)" -Level Success
    Invoke-SamAfterSccmChange
}

function Invoke-SamSetAppRetired {
    param($Apps, [bool]$Retire)
    $S = $global:SAM
    $verb = if ($Retire) { 'Retire' } else { 'Reinstate' }
    $list = @(@($Apps) | Where-Object { $_ -and ([bool]$_.Retired -ne $Retire) })
    if (-not $list.Count) { Write-SamLog "Nothing to $($verb.ToLower())." -Level Warning; return }
    $intro = "$verb these $($list.Count) application(s)?"
    $deployed = @($list | Where-Object { $_.Deployments -gt 0 })
    if ($Retire -and $deployed.Count) { $intro += "`r`n`r`n$($deployed.Count) of them still have deployments - existing installs are not removed, but they can no longer be deployed again." }
    if (-not (Confirm-SamBatch "$verb applications" $intro @($list | ForEach-Object { $_.Name }))) { return }
    $cnt = @{ N = 0 }
    Invoke-SamCM {
        foreach ($a in $list) {
            try {
                if ($Retire) { Suspend-CMApplication -Name $a.Name -ErrorAction Stop } else { Resume-CMApplication -Name $a.Name -ErrorAction Stop }
                $cnt.N++
                Write-SamLog "  $verb : $($a.Name)" -Level Success
                try { $S.App.LogAction("$verb application '$($a.Name)'") } catch { }
            }
            catch { Write-SamLog "  $($a.Name): $($_.Exception.Message)" -Level Error }
        }
    }
    Write-SamLog "$verb finished: $($cnt.N) of $($list.Count)" -Level Success
    Invoke-SamAfterSccmChange
}

function Invoke-SamRemoveApplications {
    param($Apps)
    $S = $global:SAM
    $list = @(@($Apps) | Where-Object { $_ })
    $blocked = @($list | Where-Object { $_.Deployments -gt 0 })
    foreach ($b in $blocked) { Write-SamLog "  $($b.Name) has $($b.Deployments) deployment(s) - delete them first." -Level Warning }
    $list = @($list | Where-Object { $_.Deployments -eq 0 })
    if (-not $list.Count) { Write-SamLog 'Nothing to delete.' -Level Warning; return }
    if (-not (Confirm-SamBatch 'Delete applications' "PERMANENTLY delete these $($list.Count) application(s) from site $($S.Settings.SiteCode)?`r`n(Content in the repository is not touched.)" @($list | ForEach-Object { $_.Name }))) { return }
    $cnt = @{ N = 0 }
    Invoke-SamCM {
        foreach ($a in $list) {
            try {
                Remove-CMApplication -Name $a.Name -Force -ErrorAction Stop
                $cnt.N++
                Write-SamLog "  Deleted application: $($a.Name)" -Level Success
                try { $S.App.LogAction("Deleted application '$($a.Name)'") } catch { }
            }
            catch { Write-SamLog "  $($a.Name): $($_.Exception.Message)" -Level Error }
        }
    }
    Write-SamLog "Deleted $($cnt.N) of $($list.Count) application(s)" -Level Success
    Invoke-SamAfterSccmChange
}

function Invoke-SamRemoveDeviceRecords {
    param($Devices)
    $S = $global:SAM
    $list = @(@($Devices) | Where-Object { $_ })
    if (-not $list.Count) { return }
    if (-not (Confirm-SamBatch 'Delete device records' "PERMANENTLY delete these $($list.Count) device record(s) from site $($S.Settings.SiteCode)?`r`n(Discovery may bring them back; their direct collection rules are removed.)" @($list | ForEach-Object { $_.Name }))) { return }
    $ok = 0
    foreach ($d in $list) {
        try {
            $r = Get-SamSmsData ('SELECT * FROM SMS_R_System WHERE ResourceId = {0}' -f [int]$d.ResourceID) | Select-Object -First 1
            if (-not $r) { throw 'record not found' }
            Remove-CimInstance -InputObject $r -ErrorAction Stop
            $ok++
        }
        catch {
            Write-SamLog "  WMI delete not accepted for $($d.Name) ($($_.Exception.Message)) - using the ConfigMgr cmdlet" -Level Warning
            try { Invoke-SamCM { Remove-CMResource -ResourceId ([int]$d.ResourceID) -Force -ErrorAction Stop }; $ok++ }
            catch { Write-SamLog "  $($d.Name): $($_.Exception.Message)" -Level Error; continue }
        }
        Write-SamLog "  Deleted device record: $($d.Name) ($($d.ResourceID))" -Level Success
        try { $S.App.LogAction("Deleted device record $($d.Name) ($($d.ResourceID))") } catch { }
        $dc = $S.DeviceCache
        if ($dc) { $o = $dc.ById[[int]$d.ResourceID]; if ($o) { $dc.Devices.Remove($o); $dc.ById.Remove([int]$d.ResourceID) } }
    }
    Write-SamLog "Deleted $ok of $($list.Count) device record(s)" -Level Success
    Invoke-SamRenderViews
}

function Invoke-SamClearPxe {
    param($Devices)
    $S = $global:SAM
    $list = @(@($Devices) | Where-Object { $_ })
    if (-not $list.Count) { return }
    if (-not (Confirm-SamBatch 'Clear PXE deployments' "Clear required PXE deployments for these $($list.Count) device(s)?" @($list | ForEach-Object { $_.Name }))) { return }
    $ids = [uint32[]]@($list | ForEach-Object { [uint32]$_.ResourceID })
    try {
        $r = Invoke-CimMethod -CimSession $S.Cim -Namespace $S.Ns -ClassName SMS_Collection -MethodName ClearLastNBSAdvForMachines -Arguments @{ ResourceIDs = $ids } -ErrorAction Stop
        if ($r.ReturnValue -ne 0) { throw "ClearLastNBSAdvForMachines returned $($r.ReturnValue)" }
    }
    catch {
        Write-SamLog "  WMI call not accepted ($($_.Exception.Message)) - using the ConfigMgr cmdlet" -Level Warning
        Invoke-SamCM { Clear-CMPxeDeployment -ResourceId ([string[]]@($ids | ForEach-Object { [string]$_ })) -ErrorAction Stop }
    }
    Write-SamLog "PXE deployments cleared for $($list.Count) device(s)" -Level Success
    try { $S.App.LogAction("Cleared PXE deployments: $((@($list) | ForEach-Object { $_.Name }) -join ', ')") } catch { }
}

function New-SamDeviceCollection {
    $S = $global:SAM
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "New device collection  -  site $($S.Settings.SiteCode)"
    $dlg.Size = New-Object System.Drawing.Size(620, 330)
    $dlg.StartPosition = 'CenterParent'; $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false; $dlg.ShowInTaskbar = $false
    $y = 18
    $mk = {
        param($label, $ctl)
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $label; $l.Location = New-Object System.Drawing.Point(14, ($y + 3)); $l.AutoSize = $true
        $ctl.Location = New-Object System.Drawing.Point(160, $y); $ctl.Width = 420
        $dlg.Controls.Add($l); $dlg.Controls.Add($ctl)
    }
    $txtName = New-Object System.Windows.Forms.TextBox; & $mk 'Name:' $txtName; $y += 34
    $cboLimit = New-Object System.Windows.Forms.ComboBox
    $cboLimit.DropDownStyle = 'DropDown'; $cboLimit.AutoCompleteMode = 'SuggestAppend'; $cboLimit.AutoCompleteSource = 'ListItems'
    $devColls = @($S.Cache.Collections.ToArray() | Where-Object { $_.Type -eq 'Device' })
    foreach ($c in $devColls) { [void]$cboLimit.Items.Add($c.Name) }
    $cboLimit.Text = $(if ($S.Cache.CollectionsById['SMS00001']) { $S.Cache.CollectionsById['SMS00001'].Name } else { '' })
    & $mk 'Limiting collection:' $cboLimit; $y += 34
    $cboRefresh = New-Object System.Windows.Forms.ComboBox
    $cboRefresh.DropDownStyle = 'DropDownList'
    foreach ($x in @('Manual', 'Continuous (incremental updates)')) { [void]$cboRefresh.Items.Add($x) }
    $cboRefresh.SelectedIndex = 0
    & $mk 'Membership updates:' $cboRefresh; $y += 34
    $txtComment = New-Object System.Windows.Forms.TextBox; $txtComment.Multiline = $true; $txtComment.Height = 60
    & $mk 'Comment:' $txtComment; $y += 80
    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = 'Create'; $btnOk.Size = New-Object System.Drawing.Size(120, 32); $btnOk.Location = New-Object System.Drawing.Point(330, $y)
    $btnOk.DialogResult = [System.Windows.Forms.DialogResult]::OK; $btnOk.BackColor = $global:SamClrGood
    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = 'Cancel'; $btnCancel.Size = New-Object System.Drawing.Size(120, 32); $btnCancel.Location = New-Object System.Drawing.Point(460, $y)
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dlg.Controls.Add($btnOk); $dlg.Controls.Add($btnCancel)
    $dlg.AcceptButton = $btnOk; $dlg.CancelButton = $btnCancel
    try {
        if ($dlg.ShowDialog((Get-SamOwnerForm)) -ne [System.Windows.Forms.DialogResult]::OK) { return }
        $name = $txtName.Text.Trim(); $limitName = $cboLimit.Text.Trim(); $comment = $txtComment.Text.Trim()
        $refresh = if ($cboRefresh.SelectedIndex -eq 1) { 'Continuous' } else { 'Manual' }
    }
    finally { $dlg.Dispose() }
    if (-not $name) { Write-SamLog 'A collection needs a name.' -Level Warning; return }
    if ($S.Cache.CollectionsByName.ContainsKey($name)) { Write-SamLog "A collection named '$name' already exists." -Level Warning; return }
    $limit = $S.Cache.CollectionsByName[$limitName]
    if (-not $limit -or $limit.Type -ne 'Device') { Write-SamLog "Limiting collection not found: '$limitName'" -Level Warning; return }
    $p = @{ Name = $name; LimitingCollectionId = $limit.ID; RefreshType = $refresh }
    if ($comment) { $p['Comment'] = $comment }
    $new = Invoke-SamCM { New-CMDeviceCollection @p -ErrorAction Stop }
    Write-SamLog "Created device collection '$name' ($($new.CollectionID)), limited to '$($limit.Name)'" -Level Success
    try { $S.App.LogAction("Created device collection '$name' ($($new.CollectionID)) limited to '$($limit.Name)'") } catch { }
    Invoke-SamAfterSccmChange
}

function Rename-SamCollection {
    param($Collection)
    $S = $global:SAM
    if ($Collection.BuiltIn) { Write-SamLog "'$($Collection.Name)' is built in and cannot be renamed." -Level Warning; return }
    Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction SilentlyContinue
    $newName = [Microsoft.VisualBasic.Interaction]::InputBox("New name for '$($Collection.Name)' ($($Collection.ID)):", 'Rename collection', $Collection.Name)
    $newName = ([string]$newName).Trim()
    if (-not $newName -or $newName -eq $Collection.Name) { return }
    if ($S.Cache.CollectionsByName.ContainsKey($newName)) { Write-SamLog "A collection named '$newName' already exists." -Level Warning; return }
    Invoke-SamCM { Set-CMCollection -CollectionId $Collection.ID -NewName $newName -ErrorAction Stop }
    Write-SamLog "Renamed '$($Collection.Name)' to '$newName'" -Level Success
    try { $S.App.LogAction("Renamed collection $($Collection.ID) '$($Collection.Name)' to '$newName'") } catch { }
    Invoke-SamAfterSccmChange
}

function Remove-SamCollections {
    param($Collections)
    $S = $global:SAM
    $list = New-Object System.Collections.ArrayList
    foreach ($c in @($Collections)) {
        if (-not $c) { continue }
        if ($c.BuiltIn) { Write-SamLog "  '$($c.Name)' is built in - skipped." -Level Warning; continue }
        if (($c.AppDeploys + $c.OtherDeploys) -gt 0) { Write-SamLog "  '$($c.Name)' has $($c.AppDeploys + $c.OtherDeploys) deployment(s) - delete them first." -Level Warning; continue }
        $limiters = @($S.Cache.Collections.ToArray() | Where-Object { $_.Limiting -eq $c.Name })
        if ($limiters.Count) { Write-SamLog "  '$($c.Name)' limits $($limiters.Count) other collection(s) - skipped." -Level Warning; continue }
        [void]$list.Add($c)
    }
    if (-not $list.Count) { Write-SamLog 'Nothing to delete.' -Level Warning; return }
    if (-not (Confirm-SamBatch 'Delete collections' "PERMANENTLY delete these $($list.Count) collection(s)?" @($list.ToArray() | ForEach-Object { "$($_.Name) ($($_.ID), $($_.Members) members)" }))) { return }
    $cnt = @{ N = 0 }
    Invoke-SamCM {
        foreach ($c in $list) {
            try {
                Remove-CMCollection -Id $c.ID -Force -ErrorAction Stop
                $cnt.N++
                Write-SamLog "  Deleted collection: $($c.Name) ($($c.ID))" -Level Success
                try { $S.App.LogAction("Deleted collection '$($c.Name)' ($($c.ID))") } catch { }
            }
            catch { Write-SamLog "  $($c.Name): $($_.Exception.Message)" -Level Error }
        }
    }
    Write-SamLog "Deleted $($cnt.N) of $($list.Count) collection(s)" -Level Success
    Invoke-SamAfterSccmChange
}
