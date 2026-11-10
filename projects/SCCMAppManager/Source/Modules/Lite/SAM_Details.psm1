# SAM_Details.psm1   (LITE TIER)
#
# Detail windows opened from the right-click menus / double-click:
#   Show-SamCollectionMembers     members of a collection + install status for an app
#   Show-SamCollectionDeployments deployments targeting a collection (+ status counts)
#   Show-SamDeviceCollections     collections a device is in (direct / query)
#   Show-SamDeviceDeployments     app deployments targeting a device + its status
#   Show-SamAppDeployments        deployments of an application (+ status counts)
#   Show-SamAppDeviceStatus       per-device install status of an application
# Admin-tier buttons (remove member, delete deployment) appear only when the
# admin module is loaded.

function Test-SamAdmin { param([string]$Command) return [bool](Get-Command $Command -ErrorAction SilentlyContinue) }

# Status rows for one app: MachineID -> best status text (Success > Error > In progress > Req. not met > Unknown).
function Get-SamAppStatusByMachine {
    param([string]$AppName, [string]$CollectionID = '')
    $q = 'SELECT MachineID, AppStatusType FROM SMS_AppDeploymentAssetDetails WHERE AppName = {0}' -f (ConvertTo-SamWql $AppName)
    if ($CollectionID) { $q += ' AND CollectionID = ' + (ConvertTo-SamWql $CollectionID) }
    $rows = @(Measure-SamStep "Install status for '$AppName'" { Get-SamSmsData $q })
    $rank = @{ 1 = 1; 5 = 2; 2 = 3; 3 = 4; 4 = 5 }
    $best = @{}
    foreach ($s in $rows) {
        $id = [int]$s.MachineID; $t = [int]$s.AppStatusType
        if (-not $best.ContainsKey($id) -or [int]$rank[$t] -lt [int]$rank[$best[$id]]) { $best[$id] = $t }
    }
    $out = @{}
    foreach ($id in $best.Keys) { $out[$id] = $global:SamAppStatusText[$best[$id]] }
    return $out
}

function Show-SamCollectionMembers {
    param($Collection)
    $S = $global:SAM
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Members of '$($Collection.Name)' ($($Collection.ID))  -  site $($S.Settings.SiteCode)"
    $dlg.Size = New-Object System.Drawing.Size(1200, 720)
    $dlg.StartPosition = 'CenterParent'
    $dlg.MinimizeBox = $false
    $dlg.ShowInTaskbar = $false

    $bar = New-SamToolbar
    [void](Add-SamToolbarLabel $bar 'Install status for:')
    $cbo = New-Object System.Windows.Forms.ComboBox
    $cbo.DropDownStyle = 'DropDownList'; $cbo.Width = 360; $cbo.Margin = New-Object System.Windows.Forms.Padding(3, 7, 4, 0)
    $bar.Controls.Add($cbo)
    $btnReload = New-SamButton 'Refresh' 90
    $bar.Controls.Add($btnReload)
    $editable = Test-SamEditableDeviceCollection $Collection -Quiet
    $btnAdd = $null; $btnRemove = $null
    if ($editable) {
        $btnAdd = New-SamButton 'Add devices...' 120 $global:SamClrGood
        $bar.Controls.Add($btnAdd)
        if (Test-SamAdmin 'Invoke-SamRemoveDevicesFromCollection') {
            $btnRemove = New-SamButton 'Remove selected' 130 $global:SamClrBad 'Remove the selected DIRECT members (admin)'
            $bar.Controls.Add($btnRemove)
        }
    }
    [void](Add-SamToolbarLabel $bar 'Filter:')
    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Width = 180; $txt.Margin = New-Object System.Windows.Forms.Padding(3, 7, 3, 0)
    $bar.Controls.Add($txt)
    $lbl = Add-SamToolbarLabel $bar ''

    $g = New-SamDataGrid -Key 'ResourceID' -Multi -GrayColumn 'Gray' -ColorRules @{ Status = @{ Map = $global:SamStatusColors } } -Columns @(
        @{ Name = 'Name'; Header = 'Device'; Width = 200 },
        @{ Name = 'Domain'; Width = 110 },
        @{ Name = 'Client'; Width = 60 },
        @{ Name = 'Active'; Width = 60 },
        @{ Name = 'Obsolete'; Width = 70 },
        @{ Name = 'Membership'; Width = 90 },
        @{ Name = 'Status'; Header = 'Install status'; Fill = 30 },
        @{ Name = 'ResourceID'; Header = 'Resource ID'; Type = 'int'; Width = 90 },
        @{ Name = 'Gray'; Hidden = $true })
    $g.Grid.Dock = 'Fill'
    $dlg.Controls.Add($g.Grid); $dlg.Controls.Add($bar)

    $st = @{ Rows = @(); Here = @{}; Pick = '(no status)'; Sep = '------ deployed to other collections ------'; Busy = $false; Changed = $false }

    $render = { Set-SamGridData -G $g -Items $st.Rows; Set-SamGridFilter -G $g -Text $txt.Text -CountLabel $lbl }.GetNewClosure()

    $loadMembers = {
        $q = 'SELECT ResourceID, Name, Domain, IsClient, IsActive, IsObsolete, IsDirect FROM SMS_FullCollectionMembership WHERE CollectionID = {0}' -f (ConvertTo-SamWql $Collection.ID)
        $members = @(Measure-SamStep "Members of '$($Collection.Name)'" { Get-SamSmsData $q })
        $list = New-Object System.Collections.ArrayList
        foreach ($m in ($members | Sort-Object Name)) {
            [void]$list.Add([pscustomobject]@{
                ResourceID = [int]$m.ResourceID; Name = [string]$m.Name; Domain = [string]$m.Domain
                Client = $(if ($m.IsClient) { 'Yes' } else { 'No' }); Active = $(if ($m.IsActive) { 'Yes' } else { 'No' })
                Obsolete = $(if ($m.IsObsolete) { 'Yes' } else { '' }); Membership = $(if ($m.IsDirect) { 'Direct' } else { 'Query' })
                Status = ''; Gray = ((-not $m.IsClient) -or [bool]$m.IsObsolete); IsClient = [bool]$m.IsClient; IsObsolete = [bool]$m.IsObsolete
            })
        }
        $st.Rows = $list.ToArray()
        Write-SamLog "Loaded $($list.Count) member(s) of '$($Collection.Name)'"
    }.GetNewClosure()

    $loadStatus = {
        $app = [string]$cbo.SelectedItem
        foreach ($r in $st.Rows) { $r.Status = '' }
        if ($app -and $app -ne $st.Pick -and $app -ne $st.Sep) {
            $map = if ($st.Here[$app]) { Get-SamAppStatusByMachine -AppName $app -CollectionID $Collection.ID } else { Get-SamAppStatusByMachine -AppName $app }
            $counts = @{}
            foreach ($r in $st.Rows) {
                $r.Status = if ($map.ContainsKey($r.ResourceID)) { $map[$r.ResourceID] } else { 'No status yet' }
                $counts[$r.Status] = 1 + [int]$counts[$r.Status]
            }
            Write-SamLog ("Status for '$app': " + (($counts.Keys | Sort-Object | ForEach-Object { "$_ = $($counts[$_])" }) -join ', '))
        }
        & $render
    }.GetNewClosure()

    # Applications: deployed here first, then everything deployed elsewhere
    $here = @()
    if ($S.Cache.AssignByCollId.ContainsKey($Collection.ID)) { $here = @($S.Cache.AssignByCollId[$Collection.ID] | ForEach-Object { $_.AppName } | Sort-Object -Unique) }
    foreach ($a in $here) { $st.Here[$a] = $true }
    $others = @($S.Cache.DeployedTo.Keys | Where-Object { -not $st.Here[$_] } | Sort-Object)
    [void]$cbo.Items.Add($st.Pick)
    foreach ($a in $here) { [void]$cbo.Items.Add($a) }
    if ($others.Count) { [void]$cbo.Items.Add($st.Sep); foreach ($a in $others) { [void]$cbo.Items.Add($a) } }
    $cbo.SelectedIndex = $(if ($here.Count -eq 1) { 1 } else { 0 })

    $runBusy = {
        param([scriptblock]$Work)
        if ($st.Busy) { return }
        $st.Busy = $true
        $dlg.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try { & $Work } catch { Write-SamLog "Members window: $($_.Exception.Message)" -Level Error }
        finally { $dlg.Cursor = [System.Windows.Forms.Cursors]::Default; $st.Busy = $false }
    }.GetNewClosure()

    $cbo.Add_SelectedIndexChanged({ if ($dlg.Visible) { & $runBusy { & $loadStatus } } }.GetNewClosure())
    $btnReload.Add_Click({ & $runBusy { & $loadMembers; & $loadStatus } }.GetNewClosure())
    if ($btnAdd) {
        $btnAdd.Add_Click({
            & $runBusy { Invoke-SamAddDevicesByName -Collection $Collection; & $loadMembers; & $loadStatus; $st.Changed = $true }
        }.GetNewClosure())
    }
    if ($btnRemove) {
        $btnRemove.Add_Click({
            $sel = @(Get-SamGridSelected -G $g)
            if (-not $sel.Count) { Write-SamLog 'Select one or more members first.' -Level Warning; return }
            & $runBusy { Invoke-SamRemoveDevicesFromCollection -Collection $Collection -Devices $sel; & $loadMembers; & $loadStatus; $st.Changed = $true }
        }.GetNewClosure())
    }
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 200
    $timer.Add_Tick({ $timer.Stop(); Set-SamGridFilter -G $g -Text $txt.Text -CountLabel $lbl }.GetNewClosure())
    $txt.Add_TextChanged({ $timer.Stop(); $timer.Start() }.GetNewClosure())
    Register-SamGridCount -G $g -CountLabel $lbl
    $dlg.Add_Shown({ & $runBusy { & $loadMembers; & $loadStatus } ; $g.Grid.ClearSelection() }.GetNewClosure())

    try { [void]$dlg.ShowDialog((Get-SamOwnerForm)) }
    finally { $timer.Dispose(); $dlg.Dispose() }
    if ($st.Changed) { Invoke-SamRenderViews }
}

# Deployment rows (application deployments + summary counts) for a set of assignments.
function ConvertTo-SamDeploymentRows {
    param($Assignments)
    $sumById = @{}
    foreach ($x in $global:SAM.Cache.Summaries) { if ($x.AssignmentID) { $sumById[$x.AssignmentID] = $x } }
    $rows = New-Object System.Collections.ArrayList
    foreach ($a in @($Assignments)) {
        if (-not $a) { continue }
        $x = $sumById[[string]$a.AssignmentID]
        [void]$rows.Add([pscustomobject]@{
            AssignmentID = $a.AssignmentID; Application = $a.AppName; Collection = $a.Collection; CollectionID = $a.CollectionID
            Purpose = $a.Purpose; Available = $a.Available; Deadline = $a.Deadline
            Targeted = $(if ($x) { $x.Targeted } else { 0 }); Installed = $(if ($x) { $x.Success } else { 0 })
            InProgress = $(if ($x) { $x.InProgress } else { 0 }); Failed = $(if ($x) { $x.Errors } else { 0 })
            ReqNotMet = $(if ($x) { $x.Other } else { 0 }); Unknown = $(if ($x) { $x.Unknown } else { 0 })
        })
    }
    return $rows.ToArray()
}

$global:SamDeploymentColumns = @(
    @{ Name = 'Application'; Fill = 40 },
    @{ Name = 'Collection'; Fill = 35 },
    @{ Name = 'CollectionID'; Header = 'Coll. ID'; Width = 80 },
    @{ Name = 'Purpose'; Width = 80 },
    @{ Name = 'Available'; Type = 'date'; Width = 120 },
    @{ Name = 'Deadline'; Type = 'date'; Width = 120 },
    @{ Name = 'Targeted'; Type = 'int'; Width = 70 },
    @{ Name = 'Installed'; Type = 'int'; Width = 70 },
    @{ Name = 'InProgress'; Header = 'In progress'; Type = 'int'; Width = 80 },
    @{ Name = 'Failed'; Type = 'int'; Width = 60 },
    @{ Name = 'ReqNotMet'; Header = 'Req. not met'; Type = 'int'; Width = 85 },
    @{ Name = 'Unknown'; Type = 'int'; Width = 70 })
$global:SamDeploymentRules = @{
    Failed    = @{ Positive = [System.Drawing.Color]::FromArgb(255, 210, 210) }
    ReqNotMet = @{ Positive = [System.Drawing.Color]::FromArgb(255, 243, 176) }
}

function Get-SamDeleteDeploymentButton {
    if (-not (Test-SamAdmin 'Invoke-SamRemoveDeployments')) { return $null }
    return @{ Text = 'Delete selected deployment(s)'; Width = 200; Color = $global:SamClrBad; Click = {
        param($G, $Dlg)
        $sel = @(Get-SamGridSelected -G $G)
        if (-not $sel.Count) { Write-SamLog 'Select one or more deployments first.' -Level Warning; return }
        Invoke-SamAction 'Delete deployment(s)' -NeedSccm { Invoke-SamRemoveDeployments -Deployments $sel }
        $Dlg.Close()
    } }
}

function Show-SamAppDeployments {
    param($App)
    $S = $global:SAM
    $rows = ConvertTo-SamDeploymentRows @($S.Cache.Assignments | Where-Object { $_.AppName -eq $App.Name })
    Show-SamGridDialog -Title "Deployments of '$($App.Name)'  -  site $($S.Settings.SiteCode)" -Header "$($rows.Count) deployment(s). Counts come from deployment summaries (can lag a few minutes)." `
        -Columns $global:SamDeploymentColumns -Items $rows -ColorRules $global:SamDeploymentRules -Multi -Buttons @((Get-SamDeleteDeploymentButton))
}

function Show-SamCollectionDeployments {
    param($Collection)
    $S = $global:SAM
    $rows = New-Object System.Collections.ArrayList
    foreach ($r in (ConvertTo-SamDeploymentRows $S.Cache.AssignByCollId[$Collection.ID])) { [void]$rows.Add($r) }
    $ft = @{ 2 = 'Program'; 5 = 'Software update'; 6 = 'Baseline'; 7 = 'Task sequence' }
    foreach ($x in $S.Cache.Summaries) {
        if ($x.CollectionID -ne $Collection.ID -or $x.FeatureType -eq 1) { continue }
        $kind = $ft[$x.FeatureType]; if (-not $kind) { $kind = "Type $($x.FeatureType)" }
        [void]$rows.Add([pscustomobject]@{
            AssignmentID = ''; Application = "[$kind] $($x.Software)"; Collection = $x.Collection; CollectionID = $x.CollectionID
            Purpose = $x.Intent; Available = $null; Deadline = $null
            Targeted = $x.Targeted; Installed = $x.Success; InProgress = $x.InProgress; Failed = $x.Errors; ReqNotMet = $x.Other; Unknown = $x.Unknown
        })
    }
    Show-SamGridDialog -Title "Deployments to '$($Collection.Name)' ($($Collection.ID))" -Header "$($rows.Count) deployment(s) - applications plus other types (read-only)." `
        -Columns $global:SamDeploymentColumns -Items $rows.ToArray() -ColorRules $global:SamDeploymentRules -Multi -Buttons @((Get-SamDeleteDeploymentButton))
}

function Show-SamAppDeviceStatus {
    param($App)
    $S = $global:SAM
    $q = 'SELECT MachineID, MachineName, AppStatusType, CollectionName, UserName FROM SMS_AppDeploymentAssetDetails WHERE AppName = {0}' -f (ConvertTo-SamWql $App.Name)
    $raw = @()
    try { $raw = @(Measure-SamStep "Device status for '$($App.Name)'" { Get-SamSmsData $q }) }
    catch {
        $q = 'SELECT MachineID, MachineName, AppStatusType, CollectionName FROM SMS_AppDeploymentAssetDetails WHERE AppName = {0}' -f (ConvertTo-SamWql $App.Name)
        $raw = @(Get-SamSmsData $q)
    }
    $rows = foreach ($r in $raw) {
        [pscustomobject]@{
            Device = [string]$r.MachineName; Status = [string]$global:SamAppStatusText[[int]$r.AppStatusType]
            Collection = [string]$r.CollectionName; User = $(if ($r.PSObject.Properties['UserName']) { [string]$r.UserName } else { '' })
            ResourceID = [int]$r.MachineID
        }
    }
    $rows = @($rows | Sort-Object Device)
    $counts = ($rows | Group-Object Status | Sort-Object Name | ForEach-Object { "$($_.Name) $($_.Count)" }) -join ', '
    Show-SamGridDialog -Title "Device status - '$($App.Name)'" -Header "$($rows.Count) device record(s): $counts" -Multi `
        -ColorRules @{ Status = @{ Map = $global:SamStatusColors } } -Items $rows -Columns @(
            @{ Name = 'Device'; Width = 200 },
            @{ Name = 'Status'; Width = 170 },
            @{ Name = 'Collection'; Fill = 40 },
            @{ Name = 'User'; Width = 180 },
            @{ Name = 'ResourceID'; Header = 'Resource ID'; Type = 'int'; Width = 90 })
}

function Show-SamDeviceCollections {
    param($Device)
    $S = $global:SAM
    [void](Assert-SamDeviceCache)
    $ids = $S.DeviceCache.Colls[[int]$Device.ResourceID]
    $direct = $S.DeviceCache.Direct[[int]$Device.ResourceID]
    $rows = New-Object System.Collections.ArrayList
    foreach ($cid in @($ids)) {
        if (-not $cid) { continue }
        $c = $S.Cache.CollectionsById[$cid]
        [void]$rows.Add([pscustomobject]@{
            Name = $(if ($c) { $c.Name } else { $cid }); ID = $cid
            Membership = $(if ($direct -and $direct.ContainsKey($cid)) { 'Direct' } else { 'Query / include' })
            AppDeploys = $(if ($c) { $c.AppDeploys } else { 0 }); Members = $(if ($c) { $c.Members } else { 0 })
            Folder = $(if ($c) { $c.Folder } else { '' }); Collection = $c
        })
    }
    $buttons = @()
    if (Test-SamAdmin 'Invoke-SamRemoveDevicesFromCollection') {
        $dev = $Device
        $buttons += @{ Text = 'Remove from selected (direct)'; Width = 210; Color = $global:SamClrBad; Click = {
            param($G, $Dlg)
            $sel = @(Get-SamGridSelected -G $G | Where-Object { $_.Membership -eq 'Direct' -and $_.Collection })
            if (-not $sel.Count) { Write-SamLog 'Select one or more DIRECT memberships first.' -Level Warning; return }
            foreach ($x in $sel) {
                $coll = $x.Collection
                Invoke-SamAction "Remove $($dev.Name) from '$($coll.Name)'" -NeedSccm { Invoke-SamRemoveDevicesFromCollection -Collection $coll -Devices @($dev) }
            }
            $Dlg.Close()
        }.GetNewClosure() }
    }
    Show-SamGridDialog -Title "Collections of $($Device.Name)" -Header "$($rows.Count) collection(s)" -Multi -Items ($rows.ToArray() | Sort-Object Name) -Buttons $buttons -Columns @(
        @{ Name = 'Name'; Header = 'Collection'; Fill = 50 },
        @{ Name = 'ID'; Width = 90 },
        @{ Name = 'Membership'; Width = 120 },
        @{ Name = 'AppDeploys'; Header = 'App deploys'; Type = 'int'; Width = 85 },
        @{ Name = 'Members'; Type = 'int'; Width = 75 },
        @{ Name = 'Folder'; Fill = 30 })
}

function Show-SamDeviceDeployments {
    param($Device)
    $S = $global:SAM
    [void](Assert-SamDeviceCache)
    $ids = @($S.DeviceCache.Colls[[int]$Device.ResourceID] | Where-Object { $_ })
    $status = @{}
    try {
        $q = 'SELECT AppName, CollectionID, AppStatusType FROM SMS_AppDeploymentAssetDetails WHERE MachineID = {0}' -f [int]$Device.ResourceID
        foreach ($r in @(Measure-SamStep "Deployment status for $($Device.Name)" { Get-SamSmsData $q })) {
            $status["$($r.AppName)|$($r.CollectionID)"] = [string]$global:SamAppStatusText[[int]$r.AppStatusType]
        }
    }
    catch { Write-SamLog "  Status lookup failed: $($_.Exception.Message)" -Level Warning }
    $rows = New-Object System.Collections.ArrayList
    foreach ($cid in $ids) {
        if (-not $cid) { continue }
        foreach ($a in @($S.Cache.AssignByCollId[$cid])) {
            if (-not $a) { continue }
            $k = "$($a.AppName)|$cid"
            [void]$rows.Add([pscustomobject]@{
                Application = $a.AppName; Purpose = $a.Purpose; Collection = $a.Collection; CollectionID = $cid
                Deadline = $a.Deadline; Status = $(if ($status.ContainsKey($k)) { $status[$k] } else { 'No status yet' })
            })
        }
    }
    Show-SamGridDialog -Title "Application deployments targeting $($Device.Name)" -Header "$($rows.Count) deployment(s) through $($ids.Count) collection(s)" -Multi `
        -ColorRules @{ Status = @{ Map = $global:SamStatusColors } } -Items ($rows.ToArray() | Sort-Object Application) -Columns @(
            @{ Name = 'Application'; Fill = 45 },
            @{ Name = 'Purpose'; Width = 80 },
            @{ Name = 'Status'; Width = 160 },
            @{ Name = 'Collection'; Fill = 35 },
            @{ Name = 'CollectionID'; Header = 'Coll. ID'; Width = 80 },
            @{ Name = 'Deadline'; Type = 'date'; Width = 120 })
}
