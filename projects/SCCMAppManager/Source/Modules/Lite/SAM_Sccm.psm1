# SAM_Sccm.psm1   (LITE TIER)
#
# Connection to the active environment's site and the in-memory cache.
#
# Reading uses CIM (DCOM) directly - no ConfigurationManager module needed and
# fast. The module is loaded only the first time a cmdlet is needed (create,
# deploy, export, content, delete) and is used through Invoke-SamCM, which
# switches to the site drive (one PSDrive per site code) and back.
#
# Core cache  (Update-SamCoreCache): applications, folders, application
#   deployments, collections and deployment summaries (the status counts).
# Device cache (Update-SamDeviceCache): every device + every collection
#   membership (for the Devices tab counts and add / remove).

function Get-SamSmsData {
    param([string]$Query)
    Get-CimInstance -CimSession $global:SAM.Cim -Namespace $global:SAM.Ns -Query $Query -ErrorAction Stop
}

# Tries each query in turn (richer property lists first); returns the first that works.
function Get-SamSmsDataFirst {
    param([string]$Label, $Queries)
    $last = $null
    foreach ($q in @($Queries)) {
        try { return @(Measure-SamStep "SCCM: $Label" { Get-SamSmsData $q }) }
        catch { $last = $_; Write-SamLog "  $Label query not accepted ($($_.Exception.Message)) - trying a simpler one" -Level Warning }
    }
    if ($last) { throw $last }
    return @()
}

function Import-SamCMModule {
    if ($global:SAM.CMLoaded) { return }
    if (-not $env:SMS_ADMIN_UI_PATH) { throw 'The ConfigMgr console is not installed on this machine (SMS_ADMIN_UI_PATH is not set).' }
    $psd = [IO.Path]::Combine((Split-Path $env:SMS_ADMIN_UI_PATH -Parent), 'ConfigurationManager.psd1')
    try { Measure-SamStep 'Import ConfigurationManager module (one-time)' { Import-Module $psd -Global -ErrorAction Stop -Verbose:$false } | Out-Null }
    catch {
        if (-not (Get-Module -Name ConfigurationManager)) { throw }
        Write-SamLog "  ConfigurationManager module loaded with a warning: $($_.Exception.Message)" -Level Warning
    }
    $global:SAM.CMLoaded = $true
}

# Runs ConfigMgr cmdlets on this environment's site drive, then returns to the file system.
function Invoke-SamCM {
    param([scriptblock]$__CmBlock)
    Import-SamCMModule
    $__sc = [string]$global:SAM.Settings.SiteCode
    if (-not (Get-PSDrive -Name $__sc -PSProvider CMSite -ErrorAction SilentlyContinue)) {
        New-PSDrive -Name $__sc -PSProvider CMSite -Root $global:SAM.Settings.SiteServer -Scope Global -ErrorAction Stop | Out-Null
    }
    Push-Location -LiteralPath "$($__sc):\"
    try { & $__CmBlock }
    finally { Pop-Location }
}

function Disconnect-Sam {
    $S = $global:SAM
    if ($S.Cim) { try { Remove-CimSession -CimSession $S.Cim -ErrorAction SilentlyContinue } catch { } }
    $S.Cim = $null
    $S.Connected = $false
    $S.ConnectedTo = ''
}

# Site server for a site code from the console's CMSite drives (blank SiteServer).
function Find-SamSiteServer {
    param([string]$SiteCode)
    try {
        Import-SamCMModule
        $d = Get-PSDrive -PSProvider CMSite -ErrorAction SilentlyContinue | Where-Object { $_.Name -ieq $SiteCode } | Select-Object -First 1
        if ($d) { return [string]$d.Root }
    } catch { Write-SamLog "  Site server detection: $($_.Exception.Message)" -Level Warning }
    return ''
}

function Connect-Sam {
    $S = $global:SAM
    Disconnect-Sam
    $cfg = $S.Settings
    if (-not $cfg.SiteCode) {
        Write-SamLog "Environment '$($cfg.EnvLabel)' has no site code. Set it on Environment > SCCM Site." -Level Error
        $S.ConnectFailedFor = [string]$cfg.EnvName; $S.ConnectFailedAt = Get-Date
        return $false
    }
    if (-not $cfg.SiteServer) {
        $srv = Find-SamSiteServer -SiteCode $cfg.SiteCode
        if (-not $srv) {
            Write-SamLog "No SMS Provider server for site $($cfg.SiteCode). Set it on Environment > SCCM Site (or use Detect there)." -Level Error
            $S.ConnectFailedFor = [string]$cfg.EnvName; $S.ConnectFailedAt = Get-Date
            return $false
        }
        $cfg.SiteServer = $srv
        Write-SamLog "Detected SMS Provider $srv for site $($cfg.SiteCode) (save it on Environment > SCCM Site to skip detection)." -Level Success
    }
    try {
        $S.Ns  = "root\SMS\site_$($cfg.SiteCode)"
        $S.Cim = Measure-SamStep "SCCM: open CIM session to $($cfg.SiteServer) (DCOM)" {
            New-CimSession -ComputerName $cfg.SiteServer -SessionOption (New-CimSessionOption -Protocol Dcom) -ErrorAction Stop
        }
        $null = Measure-SamStep 'SCCM: test query' { Get-SamSmsData 'SELECT SiteCode FROM SMS_Site' }
        $S.Connected   = $true
        $S.ConnectFailedFor = ""
        $S.ConnectedTo = "$($cfg.SiteCode)@$($cfg.SiteServer)"
        Write-SamLog "Connected to site $($cfg.SiteCode) on $($cfg.SiteServer)" -Level Success
        try { $S.App.LogAction("Connected to site $($cfg.SiteCode) on $($cfg.SiteServer)") } catch { }
        return $true
    }
    catch {
        Disconnect-Sam
        $S.ConnectFailedFor = [string]$cfg.EnvName; $S.ConnectFailedAt = Get-Date
        Write-SamLog "SCCM connection failed: $($_.Exception.Message)" -Level Error
        Write-SamLog "Check the site code and SMS Provider server on Environment > SCCM Site." -Level Warning
        return $false
    }
}

# Connected to THIS environment's site with the core cache loaded? Connects / loads when not.
function Assert-SamConnected {
    $S = $global:SAM
    $want = "$($S.Settings.SiteCode)@$($S.Settings.SiteServer)"
    if (-not ($S.Connected -and ($S.ConnectedTo -eq $want -or -not $S.Settings.SiteServer))) {
        if (-not (Connect-Sam)) { return $false }
    }
    if (-not $S.Cache.Loaded) { Update-SamCoreCache }
    return $true
}

# Folder paths ("Vendors\Adobe") by ContainerNodeID, from parent links.
function Get-SamFolderPaths {
    param($Nodes)
    $byId = @{}
    foreach ($f in $Nodes) { $byId[[int]$f.ContainerNodeID] = $f }
    $pathById = @{}
    foreach ($f in $Nodes) {
        $names = New-Object System.Collections.ArrayList
        $cur = $f; $guard = 0
        while ($cur -and $guard -lt 64) {
            $names.Insert(0, [string]$cur.Name)
            $parentId = [int]$cur.ParentContainerNodeID
            if ($parentId -le 0) { break }
            $cur = $byId[$parentId]; $guard++
        }
        $pathById[[int]$f.ContainerNodeID] = ($names.ToArray() -join '\')
    }
    return $pathById
}

function Update-SamCoreCache {
    $S = $global:SAM
    if (-not $S.Connected) { return }
    $apps = Get-SamSmsDataFirst 'applications' @(
        'SELECT LocalizedDisplayName, SoftwareVersion, CI_ID, ModelName, IsExpired, Manufacturer, IsSuperseded, NumberOfDeploymentTypes, DateLastModified FROM SMS_ApplicationLatest',
        'SELECT LocalizedDisplayName, SoftwareVersion, CI_ID, ModelName, IsExpired FROM SMS_ApplicationLatest')
    $nodes = @(Measure-SamStep 'SCCM: folders' { Get-SamSmsData 'SELECT ContainerNodeID, Name, ParentContainerNodeID, ObjectType FROM SMS_ObjectContainerNode WHERE ObjectType = 6000 OR ObjectType = 5000 OR ObjectType = 5001' })
    $items = @(Measure-SamStep 'SCCM: folder membership' { Get-SamSmsData 'SELECT ContainerNodeID, InstanceKey, ObjectType FROM SMS_ObjectContainerItem WHERE ObjectType = 6000 OR ObjectType = 5000 OR ObjectType = 5001' })
    $assigns = Get-SamSmsDataFirst 'application deployments' @(
        'SELECT AssignmentID, ApplicationName, CollectionName, TargetCollectionID, OfferTypeID, StartTime, EnforcementDeadline FROM SMS_ApplicationAssignment',
        'SELECT ApplicationName, CollectionName, TargetCollectionID FROM SMS_ApplicationAssignment')
    $colls = Get-SamSmsDataFirst 'collections' @(
        'SELECT CollectionID, Name, MemberCount, CollectionType, LimitToCollectionName, RefreshType, LastRefreshTime, LastMemberChangeTime, IsBuiltIn, Comment FROM SMS_Collection',
        'SELECT CollectionID, Name, MemberCount, CollectionType FROM SMS_Collection')
    $sums = @()
    try {
        $sums = Get-SamSmsDataFirst 'deployment summaries' @(
            'SELECT AssignmentID, SoftwareName, ApplicationName, CollectionID, CollectionName, FeatureType, DeploymentIntent, NumberTargeted, NumberSuccess, NumberInProgress, NumberErrors, NumberOther, NumberUnknown, SummarizationTime FROM SMS_DeploymentSummary',
            'SELECT SoftwareName, CollectionID, CollectionName, FeatureType, NumberTargeted, NumberSuccess, NumberInProgress, NumberErrors, NumberOther, NumberUnknown FROM SMS_DeploymentSummary')
    }
    catch { Write-SamLog "  Deployment summaries unavailable - status counts will be blank: $($_.Exception.Message)" -Level Warning }

    Measure-SamStep 'SCCM: build in-memory indexes' { Build-SamCoreIndexes $apps $nodes $items $assigns $colls $sums } | Out-Null
    $S.Cache.LoadedAt = Get-Date
    Write-SamLog "SCCM [$($S.Settings.SiteCode)]: $($apps.Count) applications, $($colls.Count) collections, $($assigns.Count) application deployments, $($sums.Count) deployment summaries" -Level Success
}

function Build-SamCoreIndexes {
    param($Apps, $Nodes, $Items, $Assigns, $Colls, $Sums)
    $S = $global:SAM
    $c = New-SamEmptyCache

    $appNodes  = @($Nodes | Where-Object { [int]$_.ObjectType -eq 6000 })
    $collNodes = @($Nodes | Where-Object { [int]$_.ObjectType -ne 6000 })
    $appPaths  = Get-SamFolderPaths $appNodes
    $collPaths = Get-SamFolderPaths $collNodes
    $collFolder = @{}
    foreach ($m in $Items) {
        if ([int]$m.ObjectType -eq 6000) { $c.AppFolder[[string]$m.InstanceKey] = $appPaths[[int]$m.ContainerNodeID] }
        else { $collFolder[[string]$m.InstanceKey] = $collPaths[[int]$m.ContainerNodeID] }
    }
    $c.FolderPaths = @($appPaths.Values | Sort-Object)

    # ---- application deployments ----
    $depCount = @{}; $testSet = @{}
    $testColl = [string]$S.Settings.TestCollection
    foreach ($a in $Assigns) {
        $n = [string]$a.ApplicationName
        $cn = [string]$a.CollectionName
        $cid = [string]$a.TargetCollectionID
        $o = [pscustomobject]@{
            AssignmentID = [string]$a.AssignmentID
            AppName      = $n
            Collection   = $cn
            CollectionID = $cid
            Purpose      = $(if ($null -eq $a.OfferTypeID) { '' } elseif ([int]$a.OfferTypeID -eq 0) { 'Required' } else { 'Available' })
            Available    = $a.StartTime
            Deadline     = $a.EnforcementDeadline
        }
        [void]$c.Assignments.Add($o)
        $depCount[$n] = 1 + [int]$depCount[$n]
        if ($cn -eq $testColl) { $testSet[$n] = $true }
        if (-not $c.DeployedTo.ContainsKey($n)) { $c.DeployedTo[$n] = @{} }
        $c.DeployedTo[$n][$cn] = $true
        if (-not $c.AppsByCollection.ContainsKey($cn)) { $c.AppsByCollection[$cn] = New-Object System.Collections.ArrayList }
        [void]$c.AppsByCollection[$cn].Add($n)
        if (-not $c.AssignByCollId.ContainsKey($cid)) { $c.AssignByCollId[$cid] = New-Object System.Collections.ArrayList }
        [void]$c.AssignByCollId[$cid].Add($o)
    }

    # ---- deployment summaries (status counts) ----
    $appSum = @{}; $collApp = @{}; $collOther = @{}
    foreach ($d in $Sums) {
        $sumObj = [pscustomobject]@{
            AssignmentID = [string]$d.AssignmentID
            Software     = $(if ($d.PSObject.Properties['ApplicationName'] -and [string]$d.ApplicationName) { [string]$d.ApplicationName } else { [string]$d.SoftwareName })
            CollectionID = [string]$d.CollectionID
            Collection   = [string]$d.CollectionName
            FeatureType  = [int]$d.FeatureType
            Intent       = $(if ($d.PSObject.Properties['DeploymentIntent']) { switch ([int]$d.DeploymentIntent) { 1 { 'Required' } 2 { 'Available' } 3 { 'Simulate' } default { '' } } } else { '' })
            Targeted     = [int]$d.NumberTargeted
            Success      = [int]$d.NumberSuccess
            InProgress   = [int]$d.NumberInProgress
            Errors       = [int]$d.NumberErrors
            Other        = [int]$d.NumberOther
            Unknown      = [int]$d.NumberUnknown
            Summarized   = $(if ($d.PSObject.Properties['SummarizationTime']) { $d.SummarizationTime } else { $null })
        }
        [void]$c.Summaries.Add($sumObj)
        if ($sumObj.FeatureType -eq 1) {
            $k = $sumObj.Software
            if (-not $appSum.ContainsKey($k)) { $appSum[$k] = @{ T = 0; S = 0; P = 0; E = 0; O = 0; U = 0 } }
            $h = $appSum[$k]
            $h.T += $sumObj.Targeted; $h.S += $sumObj.Success; $h.P += $sumObj.InProgress
            $h.E += $sumObj.Errors; $h.O += $sumObj.Other; $h.U += $sumObj.Unknown
            $collApp[$sumObj.CollectionID] = 1 + [int]$collApp[$sumObj.CollectionID]
        }
        else { $collOther[$sumObj.CollectionID] = 1 + [int]$collOther[$sumObj.CollectionID] }
    }

    # ---- collections ----
    foreach ($x in ($Colls | Sort-Object Name)) {
        $id = [string]$x.CollectionID
        $rt = if ($x.PSObject.Properties['RefreshType']) { [int]$x.RefreshType } else { 0 }
        $appDeps = if ($c.AssignByCollId.ContainsKey($id)) { $c.AssignByCollId[$id].Count } else { [int]$collApp[$id] }
        $o = [pscustomobject]@{
            Name        = [string]$x.Name
            ID          = $id
            Members     = [int]$x.MemberCount
            Type        = $(if ([int]$x.CollectionType -eq 1) { 'User' } else { 'Device' })
            AppDeploys  = $appDeps
            OtherDeploys = [int]$collOther[$id]
            Limiting    = $(if ($x.PSObject.Properties['LimitToCollectionName']) { [string]$x.LimitToCollectionName } else { '' })
            Refresh     = switch ($rt) { 1 { 'Manual' } 2 { 'Scheduled' } 4 { 'Incremental' } 6 { 'Incremental + Scheduled' } default { '' } }
            LastRefresh = $(if ($x.PSObject.Properties['LastRefreshTime']) { $x.LastRefreshTime } else { $null })
            LastChange  = $(if ($x.PSObject.Properties['LastMemberChangeTime']) { $x.LastMemberChangeTime } else { $null })
            Folder      = [string]$collFolder[$id]
            BuiltIn     = ($id -like 'SMS*' -or ($x.PSObject.Properties['IsBuiltIn'] -and [bool]$x.IsBuiltIn))
            Comment     = $(if ($x.PSObject.Properties['Comment']) { [string]$x.Comment } else { '' })
        }
        [void]$c.Collections.Add($o)
        if (-not $c.CollectionsByName.ContainsKey($o.Name)) { $c.CollectionsByName[$o.Name] = $o }
        $c.CollectionsById[$id] = $o
    }

    # ---- applications ----
    foreach ($a in $Apps) {
        $name  = [string]$a.LocalizedDisplayName
        $split = Split-SamAppNameVersion $name ([string]$a.SoftwareVersion)
        $h = $appSum[$name]
        $o = [pscustomobject]@{
            Name         = $name
            Version      = [string]$a.SoftwareVersion
            NameVersion  = $split.Version
            BaseName     = $split.Base
            CI_ID        = $a.CI_ID
            ModelName    = [string]$a.ModelName
            Folder       = [string]$c.AppFolder[[string]$a.ModelName]
            Publisher    = $(if ($a.PSObject.Properties['Manufacturer']) { [string]$a.Manufacturer } else { '' })
            Deployments  = [int]$depCount[$name]
            TestDeployed = [bool]$testSet[$name]
            Retired      = [bool]$a.IsExpired
            Superseded   = $(if ($a.PSObject.Properties['IsSuperseded']) { [bool]$a.IsSuperseded } else { $false })
            DTCount      = $(if ($a.PSObject.Properties['NumberOfDeploymentTypes']) { [int]$a.NumberOfDeploymentTypes } else { 0 })
            Modified     = $(if ($a.PSObject.Properties['DateLastModified']) { $a.DateLastModified } else { $null })
            Targeted     = $(if ($h) { $h.T } else { 0 })
            Installed    = $(if ($h) { $h.S } else { 0 })
            InProgress   = $(if ($h) { $h.P } else { 0 })
            Failed       = $(if ($h) { $h.E } else { 0 })
            ReqNotMet    = $(if ($h) { $h.O } else { 0 })
            Unknown      = $(if ($h) { $h.U } else { 0 })
        }
        [void]$c.Apps.Add($o)
        if (-not $c.AppsByName.ContainsKey($name)) { $c.AppsByName[$name] = $o }
        if (-not $c.AppsByBase.ContainsKey($split.Base)) { $c.AppsByBase[$split.Base] = New-Object System.Collections.ArrayList }
        [void]$c.AppsByBase[$split.Base].Add($o)
    }
    $c.Loaded = $true
    $S.Cache = $c
}

# Every device + every collection membership (Devices tab, add / remove members).
function Update-SamDeviceCache {
    $S = $global:SAM
    if (-not $S.Connected) { return }
    $devs = $null
    try {
        $devs = @(Measure-SamStep 'SCCM: devices' { Get-SamSmsData 'SELECT ResourceID, Name, IsClient, IsActive, IsObsolete, DeviceOS, LastLogonUser, LastPolicyRequest, LastActiveTime, ClientVersion, ADSiteName, Domain FROM SMS_CombinedDeviceResources WHERE ResourceType = 5' })
    }
    catch {
        Write-SamLog "  SMS_CombinedDeviceResources not available ($($_.Exception.Message)) - using SMS_R_System" -Level Warning
        $raw = @(Measure-SamStep 'SCCM: devices (SMS_R_System)' { Get-SamSmsData 'SELECT ResourceId, Name, Client, Active, Obsolete, OperatingSystemNameandVersion, LastLogonUserName, ResourceDomainORWorkgroup, ClientVersion FROM SMS_R_System' })
        $devs = foreach ($r in $raw) {
            [pscustomobject]@{ ResourceID = $r.ResourceId; Name = $r.Name; IsClient = $r.Client; IsActive = $r.Active; IsObsolete = $r.Obsolete
                DeviceOS = $r.OperatingSystemNameandVersion; LastLogonUser = $r.LastLogonUserName; LastPolicyRequest = $null; LastActiveTime = $null
                ClientVersion = $r.ClientVersion; ADSiteName = ''; Domain = $r.ResourceDomainORWorkgroup }
        }
    }
    $mem = @(Measure-SamStep 'SCCM: collection memberships' { Get-SamSmsData 'SELECT CollectionID, ResourceID, IsDirect FROM SMS_FullCollectionMembership' })

    $dc = @{ Devices = (New-Object System.Collections.ArrayList); ById = @{}; ByName = @{}; Colls = @{}; Direct = @{} }
    Measure-SamStep 'SCCM: build device indexes' {
        foreach ($m in $mem) {
            $rid = [int]$m.ResourceID
            if (-not $dc.Colls.ContainsKey($rid)) { $dc.Colls[$rid] = New-Object System.Collections.ArrayList }
            [void]$dc.Colls[$rid].Add([string]$m.CollectionID)
            if ($m.IsDirect) {
                if (-not $dc.Direct.ContainsKey($rid)) { $dc.Direct[$rid] = @{} }
                $dc.Direct[$rid][[string]$m.CollectionID] = $true
            }
        }
        foreach ($d in ($devs | Sort-Object Name)) {
            if (-not $d.Name) { continue }
            $o = [pscustomobject]@{
                ResourceID    = [int]$d.ResourceID
                Name          = ([string]$d.Name).ToUpper()
                Client        = $(if ($d.IsClient) { 'Yes' } else { 'No' })
                Active        = $(if ($d.IsActive) { 'Yes' } else { 'No' })
                Obsolete      = $(if ($d.IsObsolete) { 'Yes' } else { '' })
                OS            = [string]$d.DeviceOS
                LastUser      = [string]$d.LastLogonUser
                LastPolicy    = $d.LastPolicyRequest
                LastActive    = $d.LastActiveTime
                ClientVersion = [string]$d.ClientVersion
                ADSite        = [string]$d.ADSiteName
                Domain        = [string]$d.Domain
                IsClient      = [bool]$d.IsClient
                IsObsolete    = [bool]$d.IsObsolete
                Gray          = ((-not [bool]$d.IsClient) -or [bool]$d.IsObsolete)
                Collections   = 0
                Deployments   = 0
                Required      = 0
            }
            [void]$dc.Devices.Add($o)
            $dc.ById[$o.ResourceID] = $o
            if (-not $dc.ByName.ContainsKey($o.Name) -or ($o.IsClient -and -not $dc.ByName[$o.Name].IsClient)) { $dc.ByName[$o.Name] = $o }
        }
    } | Out-Null
    $dc.LoadedAt = Get-Date
    $S.DeviceCache = $dc
    Update-SamDeviceCounts
    Write-SamLog "SCCM [$($S.Settings.SiteCode)]: $($dc.Devices.Count) devices, $($mem.Count) collection memberships" -Level Success
}

# Collections / targeted deployments per device (from both caches).
function Update-SamDeviceCounts {
    $S = $global:SAM
    $dc = $S.DeviceCache
    if (-not $dc) { return }
    $byColl = $S.Cache.AssignByCollId
    foreach ($d in $dc.Devices) {
        $ids = $dc.Colls[$d.ResourceID]
        $n = 0; $dep = 0; $req = 0
        if ($ids) {
            foreach ($cid in $ids) {
                $n++
                $list = $byColl[$cid]
                if ($list) {
                    $dep += $list.Count
                    foreach ($a in $list) { if ($a.Purpose -eq 'Required') { $req++ } }
                }
            }
        }
        $d.Collections = $n; $d.Deployments = $dep; $d.Required = $req
    }
}

# Re-reads one collection's members and member count after a change.
function Update-SamCollectionMembership {
    param([string]$CollectionID)
    $S = $global:SAM
    $q = 'SELECT ResourceID, IsDirect FROM SMS_FullCollectionMembership WHERE CollectionID = {0}' -f (ConvertTo-SamWql $CollectionID)
    $rows = @(Get-SamSmsData $q)
    $dc = $S.DeviceCache
    if ($dc) {
        foreach ($k in @($dc.Colls.Keys)) { $dc.Colls[$k].Remove($CollectionID) }
        foreach ($k in @($dc.Direct.Keys)) { $dc.Direct[$k].Remove($CollectionID) }
        foreach ($m in $rows) {
            $rid = [int]$m.ResourceID
            if (-not $dc.Colls.ContainsKey($rid)) { $dc.Colls[$rid] = New-Object System.Collections.ArrayList }
            [void]$dc.Colls[$rid].Add($CollectionID)
            if ($m.IsDirect) {
                if (-not $dc.Direct.ContainsKey($rid)) { $dc.Direct[$rid] = @{} }
                $dc.Direct[$rid][$CollectionID] = $true
            }
        }
        Update-SamDeviceCounts
    }
    $co = $S.Cache.CollectionsById[$CollectionID]
    if ($co) {
        try {
            $x = Get-SamSmsData ('SELECT MemberCount, LastMemberChangeTime FROM SMS_Collection WHERE CollectionID = {0}' -f (ConvertTo-SamWql $CollectionID)) | Select-Object -First 1
            if ($x) { $co.Members = [int]$x.MemberCount; $co.LastChange = $x.LastMemberChangeTime }
        } catch { }
    }
}

function Get-SamCollectionInstance {
    param([string]$CollectionID)
    $c = Get-SamSmsData ('SELECT * FROM SMS_Collection WHERE CollectionID = {0}' -f (ConvertTo-SamWql $CollectionID)) | Select-Object -First 1
    if (-not $c) { throw "Collection $CollectionID not found" }
    return $c
}

# Asks the site to re-evaluate a collection now.
function Request-SamCollectionRefresh {
    param([string]$CollectionID)
    try {
        $c = Get-SamCollectionInstance $CollectionID
        $r = Invoke-CimMethod -InputObject $c -MethodName RequestRefresh -Arguments @{ IncludeSubCollections = $false } -ErrorAction Stop
        if ($r.ReturnValue -ne 0) { throw "RequestRefresh returned $($r.ReturnValue)" }
        return $true
    }
    catch {
        Write-SamLog "  WMI refresh request failed ($($_.Exception.Message)) - using the ConfigMgr cmdlet" -Level Warning
        try { Invoke-SamCM { Invoke-CMCollectionUpdate -CollectionId $CollectionID -ErrorAction Stop | Out-Null }; return $true }
        catch { Write-SamLog "  Could not request a collection update: $($_.Exception.Message)" -Level Warning; return $false }
    }
}

# Adds direct membership rules. Devices = objects with ResourceID and Name.
# WMI first (fast, no module); the ConfigMgr cmdlet when that fails. Returns the count added.
function Add-SamDirectMembers {
    param([string]$CollectionID, $Devices)
    $list = @($Devices)
    if (-not $list.Count) { return 0 }
    try {
        $cls = Get-CimClass -CimSession $global:SAM.Cim -Namespace $global:SAM.Ns -ClassName SMS_CollectionRuleDirect -ErrorAction Stop
        $rules = New-Object System.Collections.ArrayList
        foreach ($d in $list) {
            [void]$rules.Add((New-CimInstance -CimClass $cls -ClientOnly -Property @{
                ResourceClassName = 'SMS_R_System'; ResourceID = [uint32]$d.ResourceID; RuleName = [string]$d.Name }))
        }
        $coll = Get-SamCollectionInstance $CollectionID
        $arr = [Microsoft.Management.Infrastructure.CimInstance[]]$rules.ToArray()
        $r = Invoke-CimMethod -InputObject $coll -MethodName AddMembershipRules -Arguments @{ collectionRules = $arr } -ErrorAction Stop
        if ($r.ReturnValue -ne 0) { throw "AddMembershipRules returned $($r.ReturnValue)" }
        return $list.Count
    }
    catch {
        Write-SamLog "  WMI add not accepted ($($_.Exception.Message)) - using the ConfigMgr cmdlet" -Level Warning
        $ids = [int[]]@($list | ForEach-Object { [int]$_.ResourceID })
        return (Invoke-SamCM {
            try {
                Add-CMDeviceCollectionDirectMembershipRule -CollectionId $CollectionID -ResourceId $ids -ErrorAction Stop | Out-Null
                $ids.Count
            }
            catch {
                Write-SamLog "  Bulk add not accepted ($($_.Exception.Message)) - adding one at a time" -Level Warning
                $ok = 0
                foreach ($d in $list) {
                    try { Add-CMDeviceCollectionDirectMembershipRule -CollectionId $CollectionID -ResourceId ([int]$d.ResourceID) -ErrorAction Stop | Out-Null; $ok++ }
                    catch { Write-SamLog "    $($d.Name): $($_.Exception.Message)" -Level Error }
                }
                $ok
            }
        })
    }
}

# Removes direct membership rules for these devices. Returns the count removed.
function Remove-SamDirectMembers {
    param([string]$CollectionID, $Devices)
    $list = @($Devices)
    if (-not $list.Count) { return 0 }
    $want = @{}
    foreach ($d in $list) { $want[[int]$d.ResourceID] = $true }
    try {
        $coll = Get-SamCollectionInstance $CollectionID
        $full = Get-CimInstance -InputObject $coll -ErrorAction Stop       # loads the lazy CollectionRules
        $match = New-Object System.Collections.ArrayList
        foreach ($rule in @($full.CollectionRules)) {
            if ($rule.CimClass.CimClassName -eq 'SMS_CollectionRuleDirect' -and $want.ContainsKey([int]$rule.ResourceID)) { [void]$match.Add($rule) }
        }
        if (-not $match.Count) { Write-SamLog '  No matching direct rules found.' -Level Warning; return 0 }
        $arr = [Microsoft.Management.Infrastructure.CimInstance[]]$match.ToArray()
        $r = Invoke-CimMethod -InputObject $coll -MethodName DeleteMembershipRules -Arguments @{ collectionRules = $arr } -ErrorAction Stop
        if ($r.ReturnValue -ne 0) { throw "DeleteMembershipRules returned $($r.ReturnValue)" }
        return $match.Count
    }
    catch {
        Write-SamLog "  WMI remove not accepted ($($_.Exception.Message)) - using the ConfigMgr cmdlet" -Level Warning
        return (Invoke-SamCM {
            $ok = 0
            foreach ($d in $list) {
                try { Remove-CMDeviceCollectionDirectMembershipRule -CollectionId $CollectionID -ResourceId ([int]$d.ResourceID) -Force -ErrorAction Stop; $ok++ }
                catch { Write-SamLog "    $($d.Name): $($_.Exception.Message)" -Level Error }
            }
            $ok
        })
    }
}

function Resolve-SamSccmFolder {
    param([string]$FolderPath)
    if (-not $FolderPath) { return $null }
    $FolderPath = $FolderPath.Trim('\')
    foreach ($p in $global:SAM.Cache.FolderPaths) { if ($p -eq $FolderPath) { return $p } }
    $leaf = $FolderPath.Split('\')[-1]
    $hits = New-Object System.Collections.ArrayList
    foreach ($p in $global:SAM.Cache.FolderPaths) { if ($p -and $p.Split('\')[-1] -eq $leaf) { [void]$hits.Add($p) } }
    if ($hits.Count -eq 1) { return $hits[0] }
    return $null
}

# Re-renders every built SCCM tab from the caches.
function Invoke-SamRenderViews {
    foreach ($k in @($global:SAM.Views.Keys)) {
        $v = $global:SAM.Views[$k]
        if ($v) { Invoke-SamSafe "Render $k" { & $v } }
    }
}

# Reloads everything the built tabs need (button: Refresh, F5, environment switch).
function Invoke-SamReloadAll {
    param([switch]$Devices, [switch]$SkipDevices)
    $S = $global:SAM
    if (-not (Assert-SamConnected)) { return }
    if ($S.Cache.LoadedAt -and ((Get-Date) - $S.Cache.LoadedAt).TotalSeconds -gt 2) { Update-SamCoreCache }
    if (-not $SkipDevices -and ($Devices -or $S.DeviceCache)) { Update-SamDeviceCache }
    else { Update-SamDeviceCounts }
    if ($S.Views.Contains('Pipeline')) { foreach ($r in $S.Rows) { Update-SamRowSccmStatus $r } }
    $S.Stale = $false
    Invoke-SamRenderViews
}

# Auto-load is held back for 30 seconds after a failed connection to this
# environment (so every tab switch does not wait on a timeout); Refresh always tries.
function Test-SamAutoConnectBlocked {
    $S = $global:SAM
    if (-not $S.ConnectFailedFor -or $S.ConnectFailedFor -ne $S.Settings.EnvName) { return $false }
    if (-not $S.ConnectFailedAt) { return $false }
    return (((Get-Date) - $S.ConnectFailedAt).TotalSeconds -lt 30)
}