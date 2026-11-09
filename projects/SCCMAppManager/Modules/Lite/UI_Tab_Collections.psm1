# UI_Tab_Collections.psm1   (LITE TIER)
#
# Collections tab: every collection (device and user) with member and
# deployment counts. Double-click shows the members with install status.
# Right-click: members, add devices, deploy software here, deployments,
# update membership; admin tier adds new / rename / delete.

function New-SamCollectionsTab {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.TabPage]$Page,
        [Parameter(Mandatory)] $App
    )
    $Page.Tag = @{ SamView = 'Collections' }
    Set-LazyTabBuild -Page $Page -App $App -Build {
        param($Page, $App)
        [void](New-SamGridTab -Page $Page -App $App -View 'Collections' -Key 'ID' -GrayColumn 'Gray' `
            -GetItems { Get-SamCollectionItems } `
            -Columns @(
                @{ Name = 'Name'; Header = 'Collection'; Fill = 40 },
                @{ Name = 'ID'; Width = 85 },
                @{ Name = 'Type'; Width = 60 },
                @{ Name = 'Members'; Type = 'int'; Width = 75 },
                @{ Name = 'AppDeploys'; Header = 'App deploys'; Type = 'int'; Width = 85 },
                @{ Name = 'OtherDeploys'; Header = 'Other deploys'; Type = 'int'; Width = 90 },
                @{ Name = 'Limiting'; Header = 'Limiting collection'; Width = 180 },
                @{ Name = 'Refresh'; Header = 'Updates'; Width = 110 },
                @{ Name = 'LastChange'; Header = 'Members changed'; Type = 'date'; Width = 120 },
                @{ Name = 'Folder'; Width = 160 },
                @{ Name = 'Comment'; Width = 160 },
                @{ Name = 'Gray'; Hidden = $true }) `
            -Buttons @(
                @{ Text = 'New collection...'; Width = 125; Color = $global:SamClrGood; NoSelection = $true; Admin = 'New-SamDeviceCollection'; Click = { param($Sel) New-SamDeviceCollection } }) `
            -Menu @(
                @{ Text = 'Show members'; Bold = $true; Single = $true; Dialog = $true; Click = { param($Sel) Show-SamCollectionMembers -Collection $Sel[0].Source } },
                @{ Text = 'Add devices...'; Single = $true; Click = { param($Sel) Invoke-SamAddDevicesByName -Collection $Sel[0].Source } },
                @{ Text = 'Deploy software to this collection...'; Single = $true; Click = { param($Sel) Invoke-SamDeployToCollection -Collection $Sel[0].Source } },
                @{ Text = 'Show deployments'; Single = $true; Dialog = $true; Click = { param($Sel) Show-SamCollectionDeployments -Collection $Sel[0].Source } },
                @{ Separator = $true },
                @{ Text = 'Update membership now'; Click = { param($Sel) Invoke-SamUpdateMembership -Collections @($Sel | ForEach-Object { $_.Source }) } },
                @{ Text = 'Copy name(s)'; Dialog = $true; Click = { param($Sel) Set-SamClipboard @($Sel | ForEach-Object { $_.Name }) } },
                @{ Text = 'Copy ID(s)'; Dialog = $true; Click = { param($Sel) Set-SamClipboard @($Sel | ForEach-Object { $_.ID }) } },
                @{ Separator = $true },
                @{ Text = 'New device collection...'; Admin = 'New-SamDeviceCollection'; Click = { param($Sel) New-SamDeviceCollection } },
                @{ Text = 'Rename...'; Single = $true; Admin = 'Rename-SamCollection'; Click = { param($Sel) Rename-SamCollection -Collection $Sel[0].Source } },
                @{ Text = 'Delete collection(s)...'; Admin = 'Remove-SamCollections'; Click = { param($Sel) Remove-SamCollections -Collections @($Sel | ForEach-Object { $_.Source }) } }) `
            -DoubleClick { param($Item) Show-SamCollectionMembers -Collection $Item.Source })
    }
}

function Get-SamCollectionItems {
    foreach ($c in $global:SAM.Cache.Collections) {
        [pscustomobject]@{
            Name = $c.Name; ID = $c.ID; Type = $c.Type; Members = $c.Members
            AppDeploys = $c.AppDeploys; OtherDeploys = $c.OtherDeploys; Limiting = $c.Limiting
            Refresh = $c.Refresh; LastChange = $c.LastChange; Folder = $c.Folder; Comment = $c.Comment
            Gray = ($c.Members -eq 0); Source = $c
        }
    }
}

function Invoke-SamDeployToCollection {
    param($Collection)
    $S = $global:SAM
    $items = @($S.Cache.Apps.ToArray() | Where-Object { -not $_.Retired } | Sort-Object Name)
    $pick = Show-SamListPicker -Title "Deploy to '$($Collection.Name)'" -Prompt 'Application(s)' -Multi -OkText 'Next...' -Items $items -Columns @(
        @{ Name = 'Name'; Header = 'Application'; Fill = 60 },
        @{ Name = 'Version'; Width = 100 },
        @{ Name = 'Deployments'; Type = 'int'; Width = 85 },
        @{ Name = 'Folder'; Fill = 30 })
    if (-not $pick) { return }
    Invoke-SamDeployApps -AppNames @(@($pick) | ForEach-Object { $_.Name }) -CollectionID $Collection.ID
}

function Invoke-SamUpdateMembership {
    param($Collections)
    $list = @(@($Collections) | Where-Object { $_ })
    $code = Get-SamCmCode -Note 'The app calls SMS_Collection.RequestRefresh through the SMS Provider and falls back to this cmdlet.' -Lines @(
        $list | ForEach-Object { 'Invoke-CMCollectionUpdate -CollectionId ' + (Format-SamCode ([string]$_.ID)) + '   # ' + $_.Name })
    if (-not (Confirm-AppCommand -App $global:SAM.App -Title 'Update membership now' -Kind Read -RunLabel 'Update' -Code $code `
            -Summary "Ask the site to evaluate the membership of $($list.Count) collection(s) now.")) { return }
    $n = 0
    foreach ($c in @($Collections)) {
        if (-not $c) { continue }
        if (Request-SamCollectionRefresh -CollectionID $c.ID) { $n++; Write-SamLog "  Membership update requested: $($c.Name)" -Level Success }
    }
    Write-SamLog "Membership update requested for $n collection(s). Counts change after the site has evaluated them - click Refresh in a minute."
}
