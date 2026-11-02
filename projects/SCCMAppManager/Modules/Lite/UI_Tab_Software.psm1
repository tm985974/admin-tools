# UI_Tab_Software.psm1   (LITE TIER)
#
# Software tab: every application in the site, with deployment and status counts.
# Counts come from SCCM deployment summaries (refreshed by the site's summarizer,
# so they can lag a few minutes). Right-click for deploy / status / content /
# export; admin tier adds retire, reinstate and delete.

function New-SamSoftwareTab {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.TabPage]$Page,
        [Parameter(Mandatory)] $App
    )
    $Page.Tag = @{ SamView = 'Software' }
    Set-LazyTabBuild -Page $Page -App $App -Build {
        param($Page, $App)
        [void](New-SamGridTab -Page $Page -App $App -View 'Software' -Key 'Name' -GrayColumn 'Gray' `
            -GetItems { Get-SamSoftwareItems } `
            -ColorRules @{
                Failed    = @{ Positive = $global:SamClrBad }
                ReqNotMet = @{ Positive = $global:SamClrWarn }
                State     = @{ Map = @{ 'Retired' = [System.Drawing.Color]::Gainsboro } }
            } `
            -Columns @(
                @{ Name = 'Name'; Header = 'Application'; Fill = 40 },
                @{ Name = 'Version'; Width = 95 },
                @{ Name = 'Publisher'; Width = 140 },
                @{ Name = 'Folder'; Width = 170 },
                @{ Name = 'Deployments'; Type = 'int'; Width = 85 },
                @{ Name = 'Targeted'; Type = 'int'; Width = 70 },
                @{ Name = 'Installed'; Type = 'int'; Width = 70 },
                @{ Name = 'InProgress'; Header = 'In progress'; Type = 'int'; Width = 80 },
                @{ Name = 'Failed'; Type = 'int'; Width = 60 },
                @{ Name = 'ReqNotMet'; Header = 'Req. not met'; Type = 'int'; Width = 85 },
                @{ Name = 'Unknown'; Type = 'int'; Width = 70 },
                @{ Name = 'Json'; Header = 'JSON'; Width = 50 },
                @{ Name = 'State'; Width = 85 },
                @{ Name = 'Modified'; Type = 'date'; Width = 115 },
                @{ Name = 'Gray'; Hidden = $true }) `
            -Buttons @(
                @{ Text = 'Deploy...'; Width = 95; Color = [System.Drawing.Color]::MistyRose; Click = { param($Sel) Invoke-SamDeployApps -AppNames @($Sel | ForEach-Object { $_.Name }) } },
                @{ Text = 'Export to JSON'; Width = 115; Color = $global:SamClrGood; Tip = 'Write <Local Root>\<AppBaseName>_<SITE>.json for the pipeline'; Click = { param($Sel) Invoke-SamExportApps -AppNames @($Sel | ForEach-Object { $_.Name }) } }) `
            -Menu @(
                @{ Text = 'Deploy...'; Bold = $true; Click = { param($Sel) Invoke-SamDeployApps -AppNames @($Sel | ForEach-Object { $_.Name }) } },
                @{ Text = 'Show deployments'; Single = $true; Dialog = $true; Click = { param($Sel) Show-SamAppDeployments -App $Sel[0] } },
                @{ Text = 'Show device install status'; Single = $true; Dialog = $true; Click = { param($Sel) Show-SamAppDeviceStatus -App $Sel[0] } },
                @{ Separator = $true },
                @{ Text = 'Export config to JSON (pipeline)'; Click = { param($Sel) Invoke-SamExportApps -AppNames @($Sel | ForEach-Object { $_.Name }) } },
                @{ Text = 'Distribute content to DP group'; Click = { param($Sel) Invoke-SamDistributeContent -Apps $Sel } },
                @{ Text = 'Update content on distribution points'; Click = { param($Sel) Invoke-SamUpdateContent -Apps $Sel } },
                @{ Separator = $true },
                @{ Text = 'Copy name(s)'; Dialog = $true; Click = { param($Sel) Set-SamClipboard @($Sel | ForEach-Object { $_.Name }) } },
                @{ Separator = $true },
                @{ Text = 'Retire'; Admin = 'Invoke-SamSetAppRetired'; Click = { param($Sel) Invoke-SamSetAppRetired -Apps $Sel -Retire $true } },
                @{ Text = 'Reinstate'; Admin = 'Invoke-SamSetAppRetired'; Click = { param($Sel) Invoke-SamSetAppRetired -Apps $Sel -Retire $false } },
                @{ Text = 'Delete application(s)...'; Admin = 'Invoke-SamRemoveApplications'; Click = { param($Sel) Invoke-SamRemoveApplications -Apps $Sel } }) `
            -DoubleClick { param($Item) Show-SamAppDeployments -App $Item })
    }
}

function Get-SamSoftwareItems {
    $S = $global:SAM
    $json = @{}
    foreach ($r in $S.Rows) { if ($r.AppName) { $json[$r.AppName] = $true } }
    foreach ($a in $S.Cache.Apps) {
        $state = if ($a.Retired) { 'Retired' } elseif ($a.Superseded) { 'Superseded' } else { '' }
        [pscustomobject]@{
            Name = $a.Name; Version = $a.Version; Publisher = $a.Publisher
            Folder = $(if ($a.Folder) { $a.Folder } else { '(root)' })
            Deployments = $a.Deployments; Targeted = $a.Targeted; Installed = $a.Installed; InProgress = $a.InProgress
            Failed = $a.Failed; ReqNotMet = $a.ReqNotMet; Unknown = $a.Unknown
            Json = $(if ($json[$a.Name]) { 'Yes' } else { '' }); State = $state; Modified = $a.Modified
            Gray = [bool]$a.Retired
            # pass-through for actions
            Retired = $a.Retired; BaseName = $a.BaseName; NameVersion = $a.NameVersion; CI_ID = $a.CI_ID
        }
    }
}

function Set-SamClipboard {
    param($Lines)
    $t = (@($Lines) | Where-Object { $_ }) -join "`r`n"
    if ($t) { [System.Windows.Forms.Clipboard]::SetText($t); Write-SamLog "Copied $(@($Lines).Count) line(s) to the clipboard." }
}

function Invoke-SamDistributeContent {
    param($Apps)
    $S = $global:SAM
    $dpg = [string]$S.Settings.DPGroup
    if (-not $dpg) { Write-SamLog 'No DP group set for this environment (Environment > SCCM Site).' -Level Error; return }
    $list = @(@($Apps) | Where-Object { $_ })
    if (-not (Confirm-SamBatch 'Distribute content' "Distribute the content of these $($list.Count) application(s) to DP group '$dpg'?" @($list | ForEach-Object { $_.Name }))) { return }
    $cnt = @{ N = 0 }
    Invoke-SamCM {
        foreach ($a in $list) {
            try {
                Start-CMContentDistribution -ApplicationName $a.Name -DistributionPointGroupName $dpg -ErrorAction Stop | Out-Null
                $cnt.N++; Write-SamLog "  Distribution started: $($a.Name)" -Level Success
            }
            catch { Write-SamLog "  $($a.Name): $($_.Exception.Message)" -Level Warning }
        }
    }
    Write-SamLog "Content distribution started for $($cnt.N) of $($list.Count) application(s)" -Level Success
    try { $S.App.LogAction("Distributed content to '$dpg': $((@($list) | ForEach-Object { $_.Name }) -join ', ')") } catch { }
}

function Invoke-SamUpdateContent {
    param($Apps)
    $S = $global:SAM
    $list = @(@($Apps) | Where-Object { $_ })
    if (-not (Confirm-SamBatch 'Update content' "Update the content of these $($list.Count) application(s) on their distribution points?`r`n(Use after changing files in the content folder.)" @($list | ForEach-Object { $_.Name }))) { return }
    $cnt = @{ N = 0 }
    Invoke-SamCM {
        foreach ($a in $list) {
            try {
                $dts = @(Get-CMDeploymentType -ApplicationName $a.Name -ErrorAction Stop)
                foreach ($dt in $dts) {
                    Update-CMDistributionPoint -ApplicationName $a.Name -DeploymentTypeName $dt.LocalizedDisplayName -ErrorAction Stop | Out-Null
                }
                $cnt.N++; Write-SamLog "  Content update requested: $($a.Name) ($($dts.Count) deployment type(s))" -Level Success
            }
            catch { Write-SamLog "  $($a.Name): $($_.Exception.Message)" -Level Warning }
        }
    }
    Write-SamLog "Content update requested for $($cnt.N) of $($list.Count) application(s)" -Level Success
    try { $S.App.LogAction("Updated content on DPs: $((@($list) | ForEach-Object { $_.Name }) -join ', ')") } catch { }
}
