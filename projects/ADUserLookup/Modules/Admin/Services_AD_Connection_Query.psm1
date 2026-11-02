#region -- Services.AD.Connection.Query.psm1 ----------------------------------
# Concern : OU tree construction (Get-OUTree, sentinel pattern, lazy leaves),
#           Get-ChildOrganizationalUnits (lazy one-level OU child fetch, used
#           by both Get-OUTree's root build and ADDirectory.Tree.LoadChildren's
#           BeforeExpand handler), domain object fetchers (Get-DomainUsers/
#           Computers/Groups), Get-OUDirectObjects for tree leaf lazy-loading,
#           Update-DirectoryTree shim, Get-OUFromDN utility.
# Load order: 3 - depends on Services.AD.Connection (Test-ADModule)
# Split from: ADConnect.Query.psm1
# Changes   : Get-OUTree no longer recursively walks the entire OU hierarchy
#             at connect/refresh time. It now fetches only the domain root's
#             immediate child OUs (one OneLevel query) via the new
#             Get-ChildOrganizationalUnits, and gives each child OU node a
#             sentinel so it shows an expand arrow. Deeper OU levels are
#             fetched lazily by ADDirectory.Tree.LoadChildren's BeforeExpand
#             handler (Load-OUNodeLeaves), one OneLevel query per node, only
#             when the operator actually expands it. This replaces the old
#             Add-OUChildrenAD/Add-OUSentinels recursive full-tree walk, which
#             made initial connect and "Refresh Tree" cost scale with the
#             total OU count in the domain instead of just the first level.
#             Get-ChildOrganizationalUnits follows the same AD-module-first,
#             DirectorySearcher-fallback pattern already used by
#             Get-OUDirectObjects, so the fallback path also only walks one
#             level per call now instead of the whole subtree.
#             DIAGNOSTICS: Get-OUTree, Get-ChildOrganizationalUnits,
#             Get-OUDirectObjects, and Get-DomainUsers now log to the shared
#             diagnostics file (Write-ModuleDebugLog, defined in _AD-Admin.ps1
#             and available script-wide since all modules are dot-sourced
#             into the same scope) - entry parameters, which code path ran
#             (AD module vs DirectorySearcher fallback), result counts, and
#             critically the ACTUAL exception message from every catch block
#             that previously swallowed it silently. Added while
#             investigating the OU tree/Users grid not populating after the
#             lazy-tree change - this makes a genuine AD query failure (vs a
#             legitimately empty result) visible in the log instead of
#             indistinguishable from each other.
#endregion

#region -- Write-QueryDebugLog (private helper) --------------------------------
function Write-QueryDebugLog {
    # Thin wrapper so every call site here doesn't need its own Get-Command
    # guard. Write-ModuleDebugLog is defined in _AD-Admin.ps1's bootstrap
    # region, before any module is loaded, so it is always available by the
    # time this module's functions actually run (module load order 3, but
    # these functions are only ever invoked later, from UI code).
    param([string]$Text)
    if (Get-Command Write-ModuleDebugLog -ErrorAction SilentlyContinue) {
        Write-ModuleDebugLog "[Query] $Text"
    }
}
#endregion

#region -- Get-OUTree ---------------------------------------------------------
function Get-OUTree {
    <#
    .SYNOPSIS
        Returns the OU tree root node with its immediate child OUs attached
        (a single OneLevel AD query). Each child OU node gets a sentinel
        child at index 0 so it shows an expand arrow; BeforeExpand (wired in
        ADDirectory.Tree.Register, handled by Load-OUNodeLeaves in
        ADDirectory.Tree.LoadChildren) replaces the sentinel with that OU's
        own child OUs and direct object leaves on first expand. Deeper OU
        levels are never fetched until the operator expands down to them, so
        connect/refresh cost no longer scales with total OU count.
        Throws on total failure so Update-OUTree can surface the error.
    #>
    param([string]$DomainDN, [string]$Server = '')

    Write-QueryDebugLog "Get-OUTree: DomainDN='$DomainDN' Server='$Server'"

    $root      = New-Object System.Windows.Forms.TreeNode
    $root.Text = $DomainDN
    $root.Tag  = $DomainDN
    $root.Name = $DomainDN

    try {
        $children = Get-ChildOrganizationalUnits -ParentDN $DomainDN -Server $Server
        Write-QueryDebugLog "Get-OUTree: Get-ChildOrganizationalUnits returned $($children.Count) child OU(s) for root"
        foreach ($ou in $children) {
            $node = New-Object System.Windows.Forms.TreeNode
            $node.Text = $ou.Name; $node.Tag = $ou.DN; $node.Name = $ou.DN

            $sentinel      = New-Object System.Windows.Forms.TreeNode
            $sentinel.Text = ''; $sentinel.Name = '__SENTINEL__'; $sentinel.Tag = '__SENTINEL__'
            [void]$node.Nodes.Insert(0, $sentinel)

            [void]$root.Nodes.Add($node)
        }
        return $root
    } catch {
        Write-QueryDebugLog "Get-OUTree: THREW [$($_.Exception.GetType().FullName)] $($_.Exception.Message)"
        throw "OU tree build failed. Last error: $($_.Exception.Message)"
    }
}
#endregion

#region -- Get-ChildOrganizationalUnits ----------------------------------------
function Get-ChildOrganizationalUnits {
    <#
    .SYNOPSIS
        Returns the immediate child OUs (OneLevel only, not recursive) of
        $ParentDN as Name/DN pairs, sorted by Name. Used by Get-OUTree (root's
        first level) and by ADDirectory.Tree.LoadChildren's Load-OUNodeLeaves
        (any node's children, fetched lazily on expand). Falls back to
        DirectorySearcher if the AD module is unavailable. Never throws -
        returns an empty list on failure so a lazy-load expand fails quietly
        rather than surfacing an error for a single OU.
    .OUTPUTS
        List[PSCustomObject]: Name, DN
    #>
    param([string]$ParentDN, [string]$Server = '')
    Write-QueryDebugLog "Get-ChildOrganizationalUnits: ParentDN='$ParentDN' Server='$Server'"
    $out = [System.Collections.Generic.List[PSCustomObject]]::new()
    if (-not $ParentDN -or $ParentDN -eq '__SENTINEL__') {
        Write-QueryDebugLog "Get-ChildOrganizationalUnits: ParentDN blank/sentinel - returning empty"
        return ,$out
    }

    $adModuleAvailable = Test-ADModule
    Write-QueryDebugLog "Get-ChildOrganizationalUnits: Test-ADModule = $adModuleAvailable"

    if ($adModuleAvailable) {
        try {
            $p = @{
                SearchBase  = $ParentDN
                SearchScope = 'OneLevel'
                Filter      = '*'
                Properties  = @('Name','DistinguishedName')
                ErrorAction = 'Stop'
            }
            if ($Server) { $p.Server = $Server }
            $ous = Get-ADOrganizationalUnit @p | Sort-Object Name
            foreach ($ou in $ous) {
                [void]$out.Add([PSCustomObject]@{
                    Name = [string]$ou.Name
                    DN   = [string]$ou.DistinguishedName
                })
            }
            Write-QueryDebugLog "Get-ChildOrganizationalUnits: AD module path returned $($out.Count) OU(s)"
            return ,$out
        } catch {
            Write-QueryDebugLog "Get-ChildOrganizationalUnits: AD module path THREW [$($_.Exception.GetType().FullName)] $($_.Exception.Message) - falling back to DirectorySearcher"
        }
    }

    # DirectorySearcher fallback - OneLevel only, matching the AD-module path.
    try {
        $ldapPath = if ($Server) { "LDAP://$Server/$ParentDN" } else { "LDAP://$ParentDN" }
        $entry    = New-Object System.DirectoryServices.DirectoryEntry($ldapPath)
        $ds       = New-Object System.DirectoryServices.DirectorySearcher($entry)
        $ds.Filter = '(objectClass=organizationalUnit)'
        $ds.SearchScope = [System.DirectoryServices.SearchScope]::OneLevel
        $ds.PageSize    = 1000
        [void]$ds.PropertiesToLoad.AddRange(@('name','distinguishedName'))
        $found = [System.Collections.Generic.List[PSCustomObject]]::new()
        foreach ($r in $ds.FindAll()) {
            [void]$found.Add([PSCustomObject]@{
                Name = [string]($r.Properties['name']              | Select-Object -First 1)
                DN   = [string]($r.Properties['distinguishedname'] | Select-Object -First 1)
            })
        }
        foreach ($item in ($found | Sort-Object Name)) { [void]$out.Add($item) }
        Write-QueryDebugLog "Get-ChildOrganizationalUnits: DirectorySearcher fallback returned $($out.Count) OU(s)"
    } catch {
        Write-QueryDebugLog "Get-ChildOrganizationalUnits: DirectorySearcher fallback THREW [$($_.Exception.GetType().FullName)] $($_.Exception.Message)"
    }
    return ,$out
}
#endregion

#region -- Get-OUDirectObjects ------------------------------------------------
function Get-OUDirectObjects {
    <#
    .SYNOPSIS
        Returns users, groups, and computers directly in $OUDN (OneLevel only).
        Called by ADDirectory.Tree.LoadChildren during tree expansion.
    .OUTPUTS
        List[PSCustomObject]: Kind, Id, Display, DN, Enabled
    #>
    param([string]$OUDN, [string]$Server = '')
    Write-QueryDebugLog "Get-OUDirectObjects: OUDN='$OUDN' Server='$Server'"
    $out = [System.Collections.Generic.List[PSCustomObject]]::new()
    if (-not $OUDN -or $OUDN -eq '__SENTINEL__') {
        Write-QueryDebugLog "Get-OUDirectObjects: OUDN blank/sentinel - returning empty"
        return ,$out
    }

    $adModuleAvailable = Test-ADModule
    Write-QueryDebugLog "Get-OUDirectObjects: Test-ADModule = $adModuleAvailable"

    if ($adModuleAvailable) {
        try {
            $p = @{ SearchBase=$OUDN; SearchScope='OneLevel'; ErrorAction='Stop' }
            if ($Server) { $p.Server = $Server }

            $groupCount = 0
            foreach ($g in (Get-ADGroup @p -Filter '*' -Properties Name,DistinguishedName |
                            Sort-Object Name)) {
                [void]$out.Add([PSCustomObject]@{
                    Kind='Group'; Id=[string]$g.Name; Display=[string]$g.Name
                    DN=[string]$g.DistinguishedName; Enabled=$true
                })
                $groupCount++
            }
            $userCount = 0
            foreach ($u in (Get-ADUser @p -Filter '*' -Properties DisplayName,SamAccountName,Enabled,DistinguishedName |
                            Sort-Object SamAccountName)) {
                $d = if ($u.DisplayName) { "$($u.DisplayName) ($($u.SamAccountName))" } else { [string]$u.SamAccountName }
                [void]$out.Add([PSCustomObject]@{
                    Kind='User'; Id=[string]$u.SamAccountName; Display=$d
                    DN=[string]$u.DistinguishedName; Enabled=[bool]$u.Enabled
                })
                $userCount++
            }
            $compCount = 0
            foreach ($c in (Get-ADComputer @p -Filter '*' -Properties Name,Enabled,DistinguishedName |
                            Sort-Object Name)) {
                [void]$out.Add([PSCustomObject]@{
                    Kind='Computer'; Id=[string]$c.Name; Display=[string]$c.Name
                    DN=[string]$c.DistinguishedName; Enabled=[bool]$c.Enabled
                })
                $compCount++
            }
            Write-QueryDebugLog "Get-OUDirectObjects: AD module path returned $groupCount group(s), $userCount user(s), $compCount computer(s)"
            return ,$out
        } catch {
            Write-QueryDebugLog "Get-OUDirectObjects: AD module path THREW [$($_.Exception.GetType().FullName)] $($_.Exception.Message) - falling back to DirectorySearcher"
        }
    }

    # DirectorySearcher fallback
    try {
        $ldap  = if ($Server) { "LDAP://$Server/$OUDN" } else { "LDAP://$OUDN" }
        $entry = New-Object System.DirectoryServices.DirectoryEntry($ldap)
        $ds    = New-Object System.DirectoryServices.DirectorySearcher($entry)
        $ds.SearchScope = [System.DirectoryServices.SearchScope]::OneLevel
        $ds.PageSize    = 1000
        $ds.Filter      = '(|(objectCategory=person)(objectCategory=group)(objectCategory=computer))'
        [void]$ds.PropertiesToLoad.AddRange(@(
            'objectClass','name','sAMAccountName','displayName','distinguishedName','userAccountControl'))
        foreach ($r in $ds.FindAll()) {
            $classes = @($r.Properties['objectclass'] | ForEach-Object { [string]$_ })
            $name    = [string]($r.Properties['name']              | Select-Object -First 1)
            $sam     = [string]($r.Properties['samaccountname']    | Select-Object -First 1)
            $disp    = [string]($r.Properties['displayname']       | Select-Object -First 1)
            $dn      = [string]($r.Properties['distinguishedname'] | Select-Object -First 1)
            $uac     = [int]($r.Properties['useraccountcontrol']   | Select-Object -First 1)
            $enabled = -not ($uac -band 2)
            if ($classes -contains 'group') {
                [void]$out.Add([PSCustomObject]@{ Kind='Group'; Id=$name; Display=$name; DN=$dn; Enabled=$true })
            } elseif ($classes -contains 'user') {
                $id = if ($sam) { $sam } else { $name }
                $d2 = if ($disp) { "$disp ($id)" } else { $id }
                [void]$out.Add([PSCustomObject]@{ Kind='User'; Id=$id; Display=$d2; DN=$dn; Enabled=$enabled })
            }
        }
        Write-QueryDebugLog "Get-OUDirectObjects: DirectorySearcher fallback returned $($out.Count) object(s)"
    } catch {
        Write-QueryDebugLog "Get-OUDirectObjects: DirectorySearcher fallback THREW [$($_.Exception.GetType().FullName)] $($_.Exception.Message)"
    }
    return ,$out
}
#endregion

#region -- Update-DirectoryTree -----------------------------------------------
function Update-DirectoryTree {
    param([PSCustomObject]$Context)
    if (Get-Command Update-OUTree -ErrorAction SilentlyContinue) { Update-OUTree -Context $Context }
}
#endregion

#region -- Get-DomainUsers ----------------------------------------------------
function Get-DomainUsers {
    param(
        [string]$SearchBase = '', [string]$Server = '',
        [switch]$IncludeDisabled, [string[]]$Properties = @()
    )
    Write-QueryDebugLog "Get-DomainUsers: SearchBase='$SearchBase' Server='$Server' IncludeDisabled=$IncludeDisabled"
    $defaultProps = @(
        'DisplayName','SamAccountName','UserPrincipalName','GivenName','Surname',
        'Enabled','LastLogonDate','PasswordLastSet','PasswordNeverExpires',
        'PasswordExpired','LockedOut','AccountExpirationDate',
        'DistinguishedName','Description','whenCreated','whenChanged',
        'EmailAddress','Department','Title','Manager','mobile','pager'
    )
    $allProps = ($defaultProps + $Properties) | Select-Object -Unique
    $adModuleAvailable = Test-ADModule
    Write-QueryDebugLog "Get-DomainUsers: Test-ADModule = $adModuleAvailable"
    if ($adModuleAvailable) {
        try {
            $params = @{
                Filter      = if ($IncludeDisabled) { '*' } else { 'Enabled -eq $true' }
                Properties  = $allProps; ErrorAction = 'Stop'
            }
            if ($SearchBase) { $params.SearchBase = $SearchBase }
            if ($Server)     { $params.Server     = $Server }
            $result = @(Get-ADUser @params | Sort-Object SamAccountName)
            Write-QueryDebugLog "Get-DomainUsers: AD module path returned $($result.Count) user(s)"
            return $result
        } catch {
            Write-QueryDebugLog "Get-DomainUsers: AD module path THREW [$($_.Exception.GetType().FullName)] $($_.Exception.Message) - falling back to DirectorySearcher"
        }
    }
    $results = [System.Collections.Generic.List[PSCustomObject]]::new()
    try {
        $root = if ($SearchBase) {
            New-Object System.DirectoryServices.DirectoryEntry("LDAP://$SearchBase")
        } else { New-Object System.DirectoryServices.DirectoryEntry }
        $ds = New-Object System.DirectoryServices.DirectorySearcher($root)
        $ds.PageSize = 1000
        $ds.Filter   = if ($IncludeDisabled) {
            '(&(objectCategory=person)(objectClass=user))'
        } else {
            '(&(objectCategory=person)(objectClass=user)(!(userAccountControl:1.2.840.113556.1.4.803:=2)))'
        }
        [void]$ds.PropertiesToLoad.AddRange(@(
            'displayName','sAMAccountName','userPrincipalName','name','distinguishedName','description'))
        foreach ($r in $ds.FindAll()) {
            [void]$results.Add([PSCustomObject]@{
                DisplayName       = [string]($r.Properties['displayName']       | Select-Object -First 1)
                SamAccountName    = [string]($r.Properties['samaccountname']    | Select-Object -First 1)
                UserPrincipalName = [string]($r.Properties['userprincipalname'] | Select-Object -First 1)
                Name              = [string]($r.Properties['name']              | Select-Object -First 1)
                DistinguishedName = [string]($r.Properties['distinguishedname'] | Select-Object -First 1)
                Description       = [string]($r.Properties['description']       | Select-Object -First 1)
                Enabled           = $true
            })
        }
        Write-QueryDebugLog "Get-DomainUsers: DirectorySearcher fallback returned $($results.Count) user(s)"
    } catch {
        Write-QueryDebugLog "Get-DomainUsers: DirectorySearcher fallback THREW [$($_.Exception.GetType().FullName)] $($_.Exception.Message)"
    }
    return ($results | Sort-Object SamAccountName)
}
#endregion

#region -- Get-DomainComputers ------------------------------------------------
function Get-DomainComputers {
    param([string]$SearchBase = '', [string]$Server = '', [switch]$IncludeDisabled)
    $props = @('Name','Enabled','OperatingSystem','OperatingSystemVersion',
               'LastLogonDate','IPv4Address','DistinguishedName','Description',
               'whenCreated','whenChanged','DNSHostName')
    if (Test-ADModule) {
        try {
            $params = @{
                Filter      = if ($IncludeDisabled) { '*' } else { 'Enabled -eq $true' }
                Properties  = $props; ErrorAction = 'Stop'
            }
            if ($SearchBase) { $params.SearchBase = $SearchBase }
            if ($Server)     { $params.Server     = $Server }
            return (Get-ADComputer @params | Sort-Object Name)
        } catch { }
    }
    $results = [System.Collections.Generic.List[PSCustomObject]]::new()
    try {
        $root = if ($SearchBase) {
            New-Object System.DirectoryServices.DirectoryEntry("LDAP://$SearchBase")
        } else { New-Object System.DirectoryServices.DirectoryEntry }
        $ds = New-Object System.DirectoryServices.DirectorySearcher($root)
        $ds.PageSize = 1000; $ds.Filter = '(objectCategory=computer)'
        [void]$ds.PropertiesToLoad.AddRange(@(
            'name','operatingSystem','distinguishedName','description','dNSHostName'))
        foreach ($r in $ds.FindAll()) {
            [void]$results.Add([PSCustomObject]@{
                Name              = [string]($r.Properties['name']             | Select-Object -First 1)
                Enabled           = $true
                OperatingSystem   = [string]($r.Properties['operatingsystem']  | Select-Object -First 1)
                DistinguishedName = [string]($r.Properties['distinguishedname']| Select-Object -First 1)
                Description       = [string]($r.Properties['description']      | Select-Object -First 1)
                DNSHostName       = [string]($r.Properties['dnshostname']      | Select-Object -First 1)
            })
        }
    } catch { }
    return ($results | Sort-Object Name)
}
#endregion

#region -- Get-DomainGroups ---------------------------------------------------
function Get-DomainGroups {
    param([string]$SearchBase = '', [string]$Server = '')
    # PERFORMANCE NOTE: 'Members' is the single most expensive property
    # Get-ADGroup can return here - for a domain-wide security group
    # (Domain Users, Domain Computers, etc.) it means every member DN in
    # that group, on every load. It's kept because ADDirectory.Groups.Grid's
    # Member Count column needs .Members.Count, and Get-ADGroup has no
    # server-side member-count attribute - reading the full list is the
    # only way AD exposes a count (same limitation documented in
    # ADAudit.ListReports.Query.Groups's Invoke-EmptyGroupsAudit). If the
    # Groups tab is still slow after this, this property is a prime suspect
    # to profile in isolation (time the query with vs without it).
    $props = @('Name','GroupCategory','GroupScope','Description',
               'DistinguishedName','whenCreated','ManagedBy','Members')
    if (Test-ADModule) {
        try {
            $params = @{
                Filter='*'; Properties=$props; SearchScope='Subtree'; ErrorAction='Stop'
            }
            if ($SearchBase) { $params.SearchBase = $SearchBase }
            if ($Server)     { $params.Server     = $Server }
            return (Get-ADGroup @params | Sort-Object Name)
        } catch { }
    }
    $results = [System.Collections.Generic.List[PSCustomObject]]::new()
    try {
        $root = if ($SearchBase) {
            New-Object System.DirectoryServices.DirectoryEntry("LDAP://$SearchBase")
        } else { New-Object System.DirectoryServices.DirectoryEntry }
        $ds = New-Object System.DirectoryServices.DirectorySearcher($root)
        $ds.PageSize = 1000; $ds.Filter = '(objectCategory=group)'
        [void]$ds.PropertiesToLoad.AddRange(@('name','groupType','description','distinguishedName'))
        foreach ($r in $ds.FindAll()) {
            [void]$results.Add([PSCustomObject]@{
                Name              = [string]($r.Properties['name']              | Select-Object -First 1)
                GroupCategory     = 'Security'; GroupScope = 'Global'
                Description       = [string]($r.Properties['description']       | Select-Object -First 1)
                DistinguishedName = [string]($r.Properties['distinguishedname'] | Select-Object -First 1)
                whenCreated = $null; ManagedBy = ''; Members = @()
            })
        }
    } catch { }
    return ($results | Sort-Object Name)
}
#endregion

#region -- Get-OUFromDN -------------------------------------------------------
function Get-OUFromDN {
    param([string]$DN)
    if (-not $DN) { return '' }
    $parts = $DN -split ',' | Where-Object { $_ -match '^OU=' } |
             ForEach-Object { $_ -replace '^OU=','' }
    if ($parts) { return (($parts | Select-Object -Last ($parts.Count)) -join ' > ') }
    else        { return '' }
}
#endregion

Export-ModuleMember -Function `
    Get-OUTree, `
    Get-ChildOrganizationalUnits, `
    Get-OUDirectObjects, `
    Update-DirectoryTree, `
    Get-DomainUsers, `
    Get-DomainComputers, `
    Get-DomainGroups, `
    Get-OUFromDN
