# SAM_CopyEnv.psm1   (LITE TIER)
#
# Copy JSON to environment: makes a pipeline JSON for ANOTHER environment (site)
# from this environment's JSON, re-pointing what is site specific:
#   SiteCode / ExportedFrom          -> the target site
#   BaseUNCPath, CurrentContentPath,
#   DeploymentType.ContentLocation   -> <target repository>\<AppBaseName>\<Version>\
#   Application.IconLocation         -> <target icons folder>\<same file name>
#   Install / Uninstall / Repair     -> this repository path replaced by the target's
#   Application.FolderPath           -> unchanged (editable in the review)
# Every change is shown in the review dialog first. The new file is
# <target Local Root>\<AppBaseName>_<TARGETSITE>.json (or the target site's
# existing JSON for that application, after a backup). The local content folder
# is shared when both environments use the same Local Root; otherwise it can be
# copied across. Then switch to the target environment to Upload / Create / Deploy.

# Existing JSON for this application + site in a folder (any file name), or ''.
function Find-SamSiteJson {
    param([string]$Root, [string]$BaseName, [string]$SiteCode)
    if (-not [IO.Directory]::Exists($Root)) { return '' }
    $safe = $BaseName -replace '[\\/:*?"<>|]', '_'
    foreach ($f in [IO.Directory]::GetFiles($Root, "$safe*.json")) {
        try {
            $c = Read-SamAppConfig $f
            if ($c.ConfigType -eq 'SCCM Application Configuration' -and
                [string]$c.PathConfiguration.AppBaseName -eq $BaseName -and (Get-SamJsonSite $c) -eq $SiteCode) { return $f }
        } catch { }
    }
    return ''
}

function Copy-SamJsonToEnvironment {
    param($Rows)
    $S = $global:SAM
    $rows = @(@($Rows) | Where-Object { $_ -and $_.Config -and -not $_.Error })
    if (-not $rows.Count) { Write-SamLog 'Select one or more pipeline rows with a valid JSON first.' -Level Warning; return }

    $envs = @((Get-SamAllEnvironments) | Where-Object { $_.EnvName -ne $S.Settings.EnvName })
    if (-not $envs.Count) { Write-SamLog 'There is no other environment. Create one on the Environment tab first.' -Level Warning; return }
    $pick = Show-SamListPicker -Title 'Copy JSON to environment' -Prompt 'Target environment' -OkText 'Next...' -Items $envs -Columns @(
        @{ Name = 'EnvLabel'; Header = 'Environment'; Width = 160 },
        @{ Name = 'SiteCode'; Header = 'Site'; Width = 60 },
        @{ Name = 'RepositoryPath'; Header = 'Repository'; Fill = 50 },
        @{ Name = 'LocalRootResolved'; Header = 'Local Root'; Fill = 40 })
    if (-not $pick) { return }
    $t = @($pick)[0]
    if (-not $t.SiteCode) { Write-SamLog "Environment '$($t.EnvLabel)' has no site code." -Level Error; return }
    if ($t.SiteCode -eq $S.Settings.SiteCode) { Write-SamLog "Environment '$($t.EnvLabel)' is the same site ($($t.SiteCode))." -Level Error; return }
    if (-not $t.RepositoryPath) { Write-SamLog "Environment '$($t.EnvLabel)' has no repository path (Environment > SCCM Site)." -Level Error; return }
    if (-not $t.LocalRootResolved -or -not [IO.Directory]::Exists($t.LocalRootResolved)) { Write-SamLog "Local Root of '$($t.EnvLabel)' does not exist: $($t.LocalRootResolved)" -Level Error; return }

    $srcRepo = [string]$S.Settings.RepositoryPath
    $done = 0
    foreach ($r in $rows) {
        $cfg  = Read-SamAppConfig $r.JsonPath
        $base = [string]$cfg.PathConfiguration.AppBaseName
        if (-not $base) { $base = $r.BaseName }
        $ver  = [string]$cfg.PathConfiguration.CurrentVersion
        $dt   = $cfg.DeploymentType
        $newContent = [IO.Path]::Combine($t.RepositoryPath, $base, $ver).TrimEnd('\') + '\'

        $oldIcon = [string]$cfg.Application.IconLocation
        $newIcon = $oldIcon
        if ($oldIcon -and $t.IconsPath) { $newIcon = [IO.Path]::Combine($t.IconsPath, [IO.Path]::GetFileName($oldIcon)) }
        $sub = { param($x) if ($srcRepo) { Edit-SamTextLiteral ([string]$x) $srcRepo $t.RepositoryPath } else { [string]$x } }

        $fields = New-Object System.Collections.ArrayList
        [void]$fields.Add(@{ Key = 'Content'; Label = 'CONTENT LOCATION (repository of the target site)'; Old = [string]$dt.ContentLocation; New = $newContent })
        [void]$fields.Add(@{ Key = 'Icon'; Label = 'ICON'; Old = $oldIcon; New = $newIcon })
        [void]$fields.Add(@{ Key = 'Folder'; Label = 'SCCM CONSOLE FOLDER (must exist in the target site, else the app is created in the root)'; Old = [string]$cfg.Application.FolderPath; New = [string]$cfg.Application.FolderPath })
        [void]$fields.Add(@{ Key = 'Install'; Label = 'INSTALL COMMAND'; Old = [string]$dt.InstallCommand; New = (& $sub $dt.InstallCommand) })
        [void]$fields.Add(@{ Key = 'Uninstall'; Label = 'UNINSTALL COMMAND'; Old = [string]$dt.UninstallCommand; New = (& $sub $dt.UninstallCommand) })
        if ($dt.RepairCommand) { [void]$fields.Add(@{ Key = 'Repair'; Label = 'REPAIR COMMAND'; Old = [string]$dt.RepairCommand; New = (& $sub $dt.RepairCommand) }) }

        $review = Show-SamReviewDialog -Title "Copy JSON to $($t.EnvLabel) - $base" `
            -Header "$base $ver :  site $($S.Settings.SiteCode)  ->  site $($t.SiteCode)" `
            -Info "Target repository: $($t.RepositoryPath)    Target Local Root: $($t.LocalRootResolved)" -Fields $fields.ToArray()
        if ($review.Result -eq 'Skip') { Write-SamLog "  [$base] skipped"; continue }
        if ($review.Result -eq 'Cancel') { Write-SamLog '  Copy cancelled' -Level Warning; break }
        $v = $review.Values

        # Deep copy, then re-point
        $new = ($cfg | ConvertTo-Json -Depth 12) | ConvertFrom-Json
        Set-SamJsonProp $new 'SiteCode' $t.SiteCode
        if (-not $new.ExportedFrom) { Set-SamJsonProp $new 'ExportedFrom' ([pscustomobject]@{}) }
        Set-SamJsonProp $new.ExportedFrom 'SCCMSite'    $t.SiteCode
        Set-SamJsonProp $new.ExportedFrom 'SiteServer'  $t.SiteServer
        Set-SamJsonProp $new.ExportedFrom 'Environment' $t.EnvLabel
        Set-SamJsonProp $new 'CopiedFrom' ('{0} ({1}) {2} by {3}' -f $S.Settings.SiteCode, $r.JsonFile, (Get-Date -Format 'yyyy-MM-dd HH:mm'), $env:USERNAME)
        Set-SamJsonProp $new.PathConfiguration 'BaseUNCPath'        $t.RepositoryPath
        Set-SamJsonProp $new.PathConfiguration 'CurrentContentPath' $v['Content']
        Set-SamJsonProp $new.DeploymentType 'ContentLocation'  $v['Content']
        Set-SamJsonProp $new.DeploymentType 'InstallCommand'   $v['Install']
        Set-SamJsonProp $new.DeploymentType 'UninstallCommand' $v['Uninstall']
        if ($v.ContainsKey('Repair')) { Set-SamJsonProp $new.DeploymentType 'RepairCommand' $v['Repair'] }
        Set-SamJsonProp $new.Application 'IconLocation' $v['Icon']
        Set-SamJsonProp $new.Application 'FolderPath'   $v['Folder']

        $path = Find-SamSiteJson -Root $t.LocalRootResolved -BaseName $base -SiteCode $t.SiteCode
        if (-not $path) { $path = [IO.Path]::Combine($t.LocalRootResolved, ('{0}_{1}.json' -f ($base -replace '[\\/:*?"<>|]', '_'), $t.SiteCode)) }
        if ([IO.File]::Exists($path)) {
            $ans = [System.Windows.Forms.MessageBox]::Show((Get-SamOwnerForm),   # not-a-command: overwrite question
                "$([IO.Path]::GetFileName($path)) already exists for site $($t.SiteCode).`r`n`r`nOverwrite it? (A backup is kept in _Backup.)", 'Copy JSON', 'YesNo', 'Question')
            if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) { Write-SamLog "  [$base] kept the existing $path"; continue }
            Backup-SamJson $path
        }
        Save-SamAppConfig $new $path
        Write-SamLog "  [$base] written: $path" -Level Success
        try { $S.App.LogAction("Copied JSON $($r.JsonFile) to site $($t.SiteCode): $path") } catch { }
        $done++

        # Local content folder (only when the two environments use different Local Roots)
        $srcLocal = [IO.Path]::Combine($S.Settings.LocalRootResolved, $base, $ver)
        $dstLocal = [IO.Path]::Combine($t.LocalRootResolved, $base, $ver)
        if ($srcLocal -ne $dstLocal -and (Test-SamFolderHasFiles $srcLocal) -and -not (Test-SamFolderHasFiles $dstLocal)) {
            if (Confirm-AppCommand -App $S.App -Title 'Copy JSON - local content' -Kind Change -Always -RunLabel 'Copy' `
                    -Summary "Copy the local content folder too? (Cancel = no)`r`n$srcLocal`r`n  ->  $dstLocal" `
                    -Code (Get-SamRobocopyCode -Source $srcLocal -Destination $dstLocal)) { [void](Invoke-SamRobocopy -Source $srcLocal -Destination $dstLocal) }
        }
    }
    Write-SamLog "Copy finished: $done JSON file(s) written for '$($t.EnvLabel)' (site $($t.SiteCode)). Switch to that environment to Upload / Create / Deploy." -Level Success
    if ($done -and $t.LocalRootResolved -eq $S.Settings.LocalRootResolved) { Invoke-SamPipelineScan }
}
