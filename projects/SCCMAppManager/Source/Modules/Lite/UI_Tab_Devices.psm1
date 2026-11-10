# UI_Tab_Devices.psm1   (LITE TIER)
#
# Devices tab: every device in the site with its collection count and the
# application deployments targeting it (through its collections).
# Multi-select + right-click "Add to collection..." adds direct members.
# Admin tier adds remove from collection, clear PXE and delete record.

function New-SamDevicesTab {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.TabPage]$Page,
        [Parameter(Mandatory)] $App
    )
    $Page.Tag = @{ SamView = 'Devices' }
    Set-LazyTabBuild -Page $Page -App $App -Build {
        param($Page, $App)
        [void](New-SamGridTab -Page $Page -App $App -View 'Devices' -Key 'ResourceID' -NeedDevices -GrayColumn 'Gray' `
            -GetItems { if ($global:SAM.DeviceCache) { $global:SAM.DeviceCache.Devices.ToArray() } } `
            -ColorRules @{ Client = @{ Map = @{ 'No' = $global:SamClrWarn } }; Obsolete = @{ Map = @{ 'Yes' = $global:SamClrBad } } } `
            -Columns @(
                @{ Name = 'Name'; Header = 'Device'; Width = 170 },
                @{ Name = 'Client'; Width = 55 },
                @{ Name = 'Active'; Width = 55 },
                @{ Name = 'Obsolete'; Width = 65 },
                @{ Name = 'OS'; Header = 'Operating system'; Fill = 30 },
                @{ Name = 'LastUser'; Header = 'Last logon user'; Width = 140 },
                @{ Name = 'Collections'; Type = 'int'; Width = 80 },
                @{ Name = 'Deployments'; Header = 'App deploys'; Type = 'int'; Width = 85 },
                @{ Name = 'Required'; Type = 'int'; Width = 70 },
                @{ Name = 'LastPolicy'; Header = 'Last policy request'; Type = 'date'; Width = 125 },
                @{ Name = 'LastActive'; Header = 'Last active'; Type = 'date'; Width = 115 },
                @{ Name = 'ClientVersion'; Header = 'Client version'; Width = 105 },
                @{ Name = 'ADSite'; Header = 'AD site'; Width = 100 },
                @{ Name = 'Domain'; Width = 90 },
                @{ Name = 'ResourceID'; Header = 'Resource ID'; Type = 'int'; Width = 90 },
                @{ Name = 'Gray'; Hidden = $true }) `
            -Buttons @(
                @{ Text = 'Add to collection...'; Width = 140; Color = $global:SamClrGood; Tip = 'Add the selected devices to a collection (direct members)'; Click = { param($Sel) Invoke-SamAddDevicesToCollection -Devices $Sel } }) `
            -Menu @(
                @{ Text = 'Add to collection...'; Bold = $true; Click = { param($Sel) Invoke-SamAddDevicesToCollection -Devices $Sel } },
                @{ Text = 'Show collections'; Single = $true; Dialog = $true; Click = { param($Sel) Show-SamDeviceCollections -Device $Sel[0] } },
                @{ Text = 'Show deployments and status'; Single = $true; Dialog = $true; Click = { param($Sel) Show-SamDeviceDeployments -Device $Sel[0] } },
                @{ Separator = $true },
                @{ Text = 'Copy name(s)'; Dialog = $true; Click = { param($Sel) Set-SamClipboard @($Sel | ForEach-Object { $_.Name }) } },
                @{ Separator = $true },
                @{ Text = 'Remove from collection...'; Admin = 'Invoke-SamRemoveDevicesFromCollectionPick'; Click = { param($Sel) Invoke-SamRemoveDevicesFromCollectionPick -Devices $Sel } },
                @{ Text = 'Clear PXE deployments'; Admin = 'Invoke-SamClearPxe'; Click = { param($Sel) Invoke-SamClearPxe -Devices $Sel } },
                @{ Text = 'Delete device record(s)...'; Admin = 'Invoke-SamRemoveDeviceRecords'; Click = { param($Sel) Invoke-SamRemoveDeviceRecords -Devices $Sel } }) `
            -DoubleClick { param($Item) Show-SamDeviceDeployments -Device $Item })
    }
}
