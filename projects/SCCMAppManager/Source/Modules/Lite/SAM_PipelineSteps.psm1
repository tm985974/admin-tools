# SAM_PipelineSteps.psm1   (LITE TIER)
#
# Pipeline steps 1-4 (ported from v8.4). Each takes the selected pipeline rows;
# with nothing selected it acts on every row that needs that step.

function Invoke-SamAfterSccmChange {
    Update-SamCoreCache
    Update-SamDeviceCounts
    foreach ($r in $global:SAM.Rows) { Update-SamRowSccmStatus $r }
    Invoke-SamRenderViews
}

# ---------------- Step 1: Pull from Incoming ----------------

function Remove-SamOldLocalVersions {
    param($Row, [string]$Keep)
    $base = [IO.Path]::Combine($global:SAM.Settings.LocalRootResolved, $Row.BaseName)
    $keepSet = @($Keep)
    # Never delete the version the JSON points at until it is safely in the repository
    if ($Row.JsonVersion -and -not $Row.RepoHasJsonVersion) { $keepSet += $Row.JsonVersion }
    try {
        foreach ($d in [IO.Directory]::GetDirectories($base)) {
            $n = [IO.Path]::GetFileName($d)
            if ($n -match $global:SamVersionFolderRegex -and $keepSet -notcontains $n) {
                Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction Stop
                Write-SamLog "  Removed old local version: $n"
            }
        }
    }
    catch { Write-SamLog "  Could not remove old version folder: $($_.Exception.Message)" -Level Warning }
}

function Invoke-SamPullFromIncoming {
    param($Selected)
    $S = $global:SAM
    if (-not (Test-SamLocalRoot)) { return }
    $targets = @(Get-SamTargetRows $global:SamActPull ${function:Test-SamCanPull} $Selected)
    if (-not $targets.Count) { return }
    $intro = 'Copy these versions from the Incoming share to Local Root?'
    if ($S.Settings.PruneOldLocalVersions) { $intro += "`r`n(Older local version folders are removed AFTER a successful copy, except a version not yet in the repository.)" }
    $lines = $targets | ForEach-Object { '{0}: {1} -> {2}' -f $_.BaseName, (Format-SamVer $_.LocalVersion), $_.IncomingVersion }
    $code = @($targets | ForEach-Object { Get-SamRobocopyCode -Source $_.IncomingPath -Destination ([IO.Path]::Combine($S.Settings.LocalRootResolved, $_.BaseName, $_.IncomingVersion)) })
    if ($S.Settings.PruneOldLocalVersions) { $code += '# then, after a successful copy: Remove-Item -Recurse -Force on the older version folders (not one still missing from the repository)' }
    if (-not (Confirm-SamBatch 'Pull from Incoming' $intro $lines -Code ($code -join "`r`n"))) { return }

    $n = 0
    foreach ($r in $targets) {
        $n++; Set-SamProgress $n $targets.Count 'Pull'
        Write-SamLog "[$($r.BaseName)] Pulling $($r.IncomingVersion)"
        $dest = [IO.Path]::Combine($S.Settings.LocalRootResolved, $r.BaseName, $r.IncomingVersion)
        $ok = Measure-SamStep "Pull: $($r.BaseName) $($r.IncomingVersion)" { Invoke-SamRobocopy -Source $r.IncomingPath -Destination $dest }
        if ($ok -and $S.Settings.PruneOldLocalVersions) { Remove-SamOldLocalVersions -Row $r -Keep $r.IncomingVersion }
        Update-SamRow $r
    }
    Write-SamVersionsFile
    Invoke-SamRenderViews
}

# ---------------- Step 2: Update JSON ----------------

function Update-SamAppJson {
    param($Row)
    $S = $global:SAM
    $cfg  = Read-SamAppConfig $Row.JsonPath
    $base = $Row.BaseName
    $old  = [string]$cfg.PathConfiguration.CurrentVersion
    $new  = [string]$Row.LocalVersion
    $dt   = $cfg.DeploymentType
    if (-not $dt) { Write-SamLog '  JSON has no DeploymentType section - cannot update.' -Level Error; return 'Failed' }

    $localFolder = [IO.Path]::Combine($S.Settings.LocalRootResolved, $base, $new)
    $repoFolder  = [IO.Path]::Combine($S.Settings.RepositoryPath, $base, $new) + '\'

    $oldPrimary = $null
    if ($dt.InstallerFiles) { $oldPrimary = [string]$dt.InstallerFiles.PrimaryFile }
    $installer = Measure-SamStep "  Find installer ($base)" { Find-SamPrimaryInstaller -Folder $localFolder -PreferName $oldPrimary }
    $msi = if ($installer -and $installer.Type -eq 'MSI') { $installer.FullPath } else { Find-SamFirstFile $localFolder '*.msi' }
    $newCode = $null
    if ($msi) { $newCode = Measure-SamStep "  Read MSI ProductCode ($base)" { Get-SamMsiProductCode $msi } }
    $oldCode = [string]$dt.ProductCode
    if ($newCode -and -not $oldCode) { Write-SamLog '  JSON has no ProductCode; any GUID in the commands will be replaced - check the review.' -Level Warning }

    $common = @{
        OldVersion = $old; NewVersion = $new; OldCode = $oldCode; NewCode = $newCode
        OldFile = $oldPrimary; NewFile = $(if ($installer) { $installer.Name } else { $null })
    }
    $fields = New-Object System.Collections.ArrayList
    [void]$fields.Add(@{ Key = 'Install';   Label = 'INSTALL COMMAND';   Old = [string]$dt.InstallCommand;   New = (Get-SamProposedText -Text $dt.InstallCommand @common) })
    [void]$fields.Add(@{ Key = 'Uninstall'; Label = 'UNINSTALL COMMAND'; Old = [string]$dt.UninstallCommand; New = (Get-SamProposedText -Text $dt.UninstallCommand @common) })
    if ($dt.RepairCommand) {
        [void]$fields.Add(@{ Key = 'Repair'; Label = 'REPAIR COMMAND'; Old = [string]$dt.RepairCommand; New = (Get-SamProposedText -Text $dt.RepairCommand @common) })
    }
    $det = $null
    if ($dt.DetectionMethod) { $det = [string]$dt.DetectionMethod.ScriptText }
    if ($det) {
        [void]$fields.Add(@{ Key = 'Detection'; Label = 'DETECTION SCRIPT'; Old = $det; New = (Get-SamProposedText -Text $det -Detection @common); Tall = $true })
    }

    $info = 'Installer: {0}    ProductCode: {1} -> {2}' -f $(if ($installer) { $installer.Name } else { '(none found)' }),
            $(if ($oldCode) { $oldCode } else { '(none)' }), $(if ($newCode) { $newCode } else { '(n/a)' })
    $review = Show-SamReviewDialog -Title "Update JSON - $base" -Header "$base :  $old  ->  $new" -Info $info -Fields $fields.ToArray()

    if ($review.Result -eq 'Skip')   { Write-SamLog '  Skipped by user'; return 'Skipped' }
    if ($review.Result -eq 'Cancel') { Write-SamLog '  Cancelled by user' -Level Warning; return 'Cancelled' }

    Backup-SamJson $Row.JsonPath
    $v = $review.Values

    if (-not (Get-SamJsonSite $cfg)) { Set-SamJsonProp $cfg 'SiteCode' $S.Settings.SiteCode }
    Set-SamJsonProp $cfg.Application 'Name'            "$base $new"
    Set-SamJsonProp $cfg.Application 'LocalizedName'   "$base $new"
    Set-SamJsonProp $cfg.Application 'SoftwareVersion' $new
    Set-SamJsonProp $cfg.Application 'ReleaseDate'     (Get-Date -Format 'yyyy-MM-dd')

    Set-SamJsonProp $cfg.PathConfiguration 'CurrentVersion'     $new
    Set-SamJsonProp $cfg.PathConfiguration 'CurrentContentPath' $repoFolder
    Set-SamJsonProp $cfg.PathConfiguration 'BaseUNCPath'        $S.Settings.RepositoryPath

    Set-SamJsonProp $dt 'DeploymentTypeName' "$base $new"
    Set-SamJsonProp $dt 'ContentLocation'    $repoFolder
    Set-SamJsonProp $dt 'InstallCommand'     $v['Install']
    Set-SamJsonProp $dt 'UninstallCommand'   $v['Uninstall']
    if ($v.ContainsKey('Repair')) { Set-SamJsonProp $dt 'RepairCommand' $v['Repair'] }
    if ($newCode) { Set-SamJsonProp $dt 'ProductCode' $newCode }
    if ($installer) {
        if (-not $dt.InstallerFiles) { Set-SamJsonProp $dt 'InstallerFiles' ([pscustomobject]@{}) }
        $top = @([IO.Directory]::GetFiles($localFolder) | ForEach-Object { [IO.Path]::GetFileName($_) })
        Set-SamJsonProp $dt.InstallerFiles 'PrimaryFile' $installer.Name
        Set-SamJsonProp $dt.InstallerFiles 'PrimaryType' $installer.Type
        Set-SamJsonProp $dt.InstallerFiles 'AllFiles'    $top
    }
    if ($v.ContainsKey('Detection')) {
        Set-SamJsonProp $dt.DetectionMethod 'ScriptText'   $v['Detection']
        Set-SamJsonProp $dt.DetectionMethod 'ScriptLength' ([string]$v['Detection']).Length
    }
    if ($cfg.VersionPatterns) { Set-SamJsonProp $cfg.VersionPatterns 'ExtractedVersion' $new }

    Save-SamAppConfig $cfg $Row.JsonPath
    Write-SamLog "  JSON updated: $($Row.JsonPath)" -Level Success
    return 'Applied'
}

function Invoke-SamUpdateJson {
    param($Selected)
    if (-not (Test-SamLocalRoot)) { return }
    $targets = @(Get-SamTargetRows $global:SamActJson ${function:Test-SamCanUpdateJson} $Selected)
    $n = 0
    foreach ($r in $targets) {
        $n++; Set-SamProgress $n $targets.Count 'Update JSON'
        Write-SamLog "[$($r.BaseName)] Update JSON $($r.JsonVersion) -> $($r.LocalVersion)"
        $result = Measure-SamStep "Update JSON: $($r.BaseName)" { Update-SamAppJson -Row $r }
        Update-SamRow $r
        if ($result -eq 'Cancelled') { break }
    }
    Invoke-SamRenderViews
}

# ---------------- Step 3: Upload to Repository ----------------

function Invoke-SamUploadToRepository {
    param($Selected)
    $S = $global:SAM
    if (-not (Test-SamLocalRoot)) { return }
    if (-not $S.Settings.RepositoryPath) { Write-SamLog 'No repository path for this environment (Environment > SCCM Site).' -Level Error; return }
    $targets = @(Get-SamTargetRows $global:SamActUpload ${function:Test-SamCanUpload} $Selected)
    if (-not $targets.Count) { return }
    $lines = $targets | ForEach-Object { '{0} {1}' -f $_.BaseName, $_.JsonVersion }
    $code = @($targets | ForEach-Object { Get-SamRobocopyCode -Source ([IO.Path]::Combine($S.Settings.LocalRootResolved, $_.BaseName, $_.JsonVersion)) -Destination ([IO.Path]::Combine($S.Settings.RepositoryPath, $_.BaseName, $_.JsonVersion)) }) -join "`r`n"
    if (-not (Confirm-SamBatch 'Upload to Repository' "Upload these version folders to $($S.Settings.RepositoryPath) ?" $lines -Code $code)) { return }

    $n = 0; $ok = 0
    foreach ($r in $targets) {
        $n++; Set-SamProgress $n $targets.Count 'Upload'
        Write-SamLog "[$($r.BaseName)] Uploading $($r.JsonVersion)"
        $src = [IO.Path]::Combine($S.Settings.LocalRootResolved, $r.BaseName, $r.JsonVersion)
        $dst = [IO.Path]::Combine($S.Settings.RepositoryPath, $r.BaseName, $r.JsonVersion)
        if (Measure-SamStep "Upload: $($r.BaseName) $($r.JsonVersion)" { Invoke-SamRobocopy -Source $src -Destination $dst }) {
            $ok++
            try { $S.App.LogAction("Uploaded $($r.BaseName) $($r.JsonVersion) to $dst") } catch { }
        }
        Update-SamRow $r
    }
    Write-SamLog "Upload finished: $ok of $($targets.Count) succeeded" -Level Success
    Invoke-SamRenderViews
}

# ---------------- Step 4: Create in SCCM ----------------

function Get-SamAllowed {
    param($Value, $Allowed, [string]$Default)
    foreach ($a in @($Allowed)) { if ([string]$Value -eq $a) { return $a } }
    return $Default
}

# Everything New-SamSccmAppFromConfig passes to the ConfigMgr cmdlets, built once
# so the command window (Get-SamCreateCommandText) shows exactly what runs.
# Returns Ok / Error / Name / Content / App (New-CMApplication) / DT
# (Add-CMScriptDeploymentType) / Folder / Warnings.
function Get-SamAppCreateSpec {
    param($Config)
    $S = $global:SAM
    $app = $Config.Application; $dt = $Config.DeploymentType; $pc = $Config.PathConfiguration
    $name = [string]$app.Name
    $spec = [pscustomobject]@{ Ok = $false; Error = ''; Name = $name; Content = ''; App = $null; DT = $null; Folder = [string]$app.FolderPath; Warnings = (New-Object System.Collections.ArrayList) }

    if (-not $name -or -not $app.SoftwareVersion) { $spec.Error = 'Application.Name / SoftwareVersion missing in JSON'; return $spec }
    if (-not $dt -or -not $dt.InstallCommand)      { $spec.Error = 'No DeploymentType / InstallCommand in JSON'; return $spec }
    $detection = if ($dt.DetectionMethod) { [string]$dt.DetectionMethod.ScriptText } else { '' }
    if (-not $detection) { $spec.Error = 'No detection script in JSON (script detection is required)'; return $spec }

    $content = [IO.Path]::Combine($S.Settings.RepositoryPath, [string]$pc.AppBaseName, [string]$pc.CurrentVersion).TrimEnd('\') + '\'
    $spec.Content = $content
    if (-not (Test-SamFolderHasFiles $content)) { $spec.Error = "Content not found in repository: $content (run Upload first)"; return $spec }

    $p = @{
        Name            = $name
        LocalizedName   = $(if ($app.LocalizedName) { [string]$app.LocalizedName } else { $name })
        SoftwareVersion = [string]$app.SoftwareVersion
        ReleaseDate     = (Get-Date).Date      # must be [DateTime]; a string causes "Invalid operation"
    }
    if ($app.Publisher -and ([string]$app.Publisher).Trim())     { $p['Publisher']   = ([string]$app.Publisher).Trim() }
    if ($app.Description -and ([string]$app.Description).Trim()) { $p['Description'] = ([string]$app.Description).Trim() }
    $kw = @($app.Keywords | Where-Object { $_ -and ([string]$_).Trim() } | ForEach-Object { ([string]$_).Trim() })
    if ($kw.Count) { $p['Keyword'] = $kw -join '; ' }

    $icon = [string]$app.IconLocation
    if ($icon) {
        if ([IO.File]::Exists($icon)) {
            $len = (New-Object IO.FileInfo $icon).Length
            $ext = [IO.Path]::GetExtension($icon).ToLower()
            if ($len -gt 0 -and $len -lt 5MB -and @('.ico', '.png', '.jpg', '.jpeg', '.gif', '.bmp') -contains $ext) { $p['IconLocationFile'] = $icon }
            else { [void]$spec.Warnings.Add("Icon rejected ($ext, $len bytes) - creating without icon") }
        }
        else { [void]$spec.Warnings.Add("Icon not found: $icon - creating without icon") }
    }
    $spec.App = $p

    $dtParams = @{
        ApplicationName          = $name
        DeploymentTypeName       = $(if ($dt.DeploymentTypeName) { [string]$dt.DeploymentTypeName } else { $name })
        InstallCommand           = [string]$dt.InstallCommand
        ContentLocation          = $content
        ScriptLanguage           = (Get-SamAllowed $dt.DetectionMethod.ScriptLanguage @('PowerShell', 'VBScript', 'JavaScript') 'PowerShell')
        ScriptText               = $detection
        InstallationBehaviorType = (Get-SamAllowed $dt.InstallationBehavior.Type @('InstallForSystem', 'InstallForUser', 'InstallForSystemIfResourceIsDeviceOtherwiseInstallForUser') 'InstallForSystem')
        LogonRequirementType     = (Get-SamAllowed $dt.LogonRequirement.Type @('OnlyWhenNoUserLoggedOn', 'OnlyWhenUserLoggedOn', 'WhetherOrNotUserLoggedOn') 'WhetherOrNotUserLoggedOn')
        UserInteractionMode      = (Get-SamAllowed $dt.UserInteraction.Mode @('Normal', 'Hidden', 'Maximized', 'Minimized') 'Hidden')
        RebootBehavior           = (Get-SamAllowed $dt.RebootBehavior.Type @('BasedOnExitCode', 'NoAction', 'ForceReboot', 'ProgramReboot') 'BasedOnExitCode')
    }
    if ($dt.UninstallCommand) { $dtParams['UninstallCommand'] = [string]$dt.UninstallCommand }
    if ($dt.RepairCommand)    { $dtParams['RepairCommand']    = [string]$dt.RepairCommand }
    if ($dt.ExecutionTime) {
        if ([int]$dt.ExecutionTime.MaximumMinutes -gt 0)   { $dtParams['MaximumRuntimeMins']   = [int]$dt.ExecutionTime.MaximumMinutes }
        if ([int]$dt.ExecutionTime.EstimatedMinutes -gt 0) { $dtParams['EstimatedRuntimeMins'] = [int]$dt.ExecutionTime.EstimatedMinutes }
    }

    $spec.DT = $dtParams
    $spec.Ok = $true
    return $spec
}

# The command window text for creating these applications (from their JSON).
function Get-SamCreateCommandText {
    param($Configs)
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($cfg in @($Configs)) {
        $spec = Get-SamAppCreateSpec -Config $cfg
        if (-not $spec.Ok) { $lines.Add("# $($spec.Name): not created - $($spec.Error)"); continue }
        $lines.Add('')
        $lines.Add("# ---- $($spec.Name)")
        $lines.Add('$app = ' + (Format-SamCode $spec.App))
        $lines.Add('New-CMApplication @app')
        $lines.Add('$dt = ' + (Format-SamCode $spec.DT))
        $lines.Add('Add-CMScriptDeploymentType @dt   # on failure the app removes the half-made application')
        if ($spec.Folder) { $lines.Add('Move-CMObject -InputObject (Get-CMApplication -Name ' + (Format-SamCode $spec.Name) + ') -FolderPath ' + (Format-SamCode ("$($global:SAM.Settings.SiteCode):\Application\$($spec.Folder)"))) }
    }
    return (Get-SamCmCode -Lines $lines -Note 'If New-CMApplication rejects an optional value, the app retries without it (and logs which one).')
}

function New-SamSccmAppFromConfig {
    param($Config)
    $S = $global:SAM
    $app = $Config.Application
    $spec = Get-SamAppCreateSpec -Config $Config
    if (-not $spec.Ok) { Write-SamLog "  $($spec.Error)" -Level Error; return $false }
    $name = $spec.Name
    $content = $spec.Content
    Write-SamLog "  Content: $content"
    foreach ($w in $spec.Warnings) { Write-SamLog "  $w" -Level Warning }
    $p = $spec.App
    $dtParams = $spec.DT
    Write-SamLog ('  New-CMApplication parameters: ' + (($p.Keys | Sort-Object) -join ', '))

    $newApp = Invoke-SamCM {
        try { New-CMApplication @p -ErrorAction Stop }
        catch {
            Write-SamLog "  New-CMApplication failed: $($_.Exception.Message)" -Level Warning
            $result = $null
            foreach ($k in @('ReleaseDate', 'Keyword', 'IconLocationFile', 'Description', 'Publisher')) {
                if (-not $p.ContainsKey($k)) { continue }
                [void]$p.Remove($k)
                Write-SamLog "  Retrying without -$k ..." -Level Warning
                try {
                    $result = New-CMApplication @p -ErrorAction Stop
                    Write-SamLog "  Created without -$k - that parameter caused the error; set it manually." -Level Warning
                    break
                }
                catch { Write-SamLog "    Still failing: $($_.Exception.Message)" -Level Warning }
            }
            $result
        }
    }
    if (-not $newApp) { Write-SamLog '  Application could not be created.' -Level Error; return $false }
    Write-SamLog '  Application created' -Level Success

    $dtOk = Measure-SamStep "  Add deployment type ($name)" {
        Invoke-SamCM {
            try { $null = Add-CMScriptDeploymentType @dtParams -ErrorAction Stop; $true }
            catch {
                Write-SamLog "  Add-CMScriptDeploymentType failed: $($_.Exception.Message)" -Level Error
                Write-SamLog '  Removing the partially created application...' -Level Warning
                Remove-CMApplication -Name $name -Force -ErrorAction SilentlyContinue
                $false
            }
        }
    }
    if (-not $dtOk) { return $false }
    Write-SamLog '  Deployment type created' -Level Success

    if ($app.FolderPath) {
        $folder = Resolve-SamSccmFolder ([string]$app.FolderPath)
        if ($folder) {
            try {
                Invoke-SamCM {
                    $fresh = Get-CMApplication -Name $name -ErrorAction Stop
                    Move-CMObject -InputObject $fresh -FolderPath "$($S.Settings.SiteCode):\Application\$folder" -ErrorAction Stop
                }
                Write-SamLog "  Moved to folder: $folder" -Level Success
            }
            catch { Write-SamLog "  Could not move to folder '$folder': $($_.Exception.Message)" -Level Warning }
        }
        else { Write-SamLog "  Folder '$($app.FolderPath)' not found in site $($S.Settings.SiteCode) - left in the root" -Level Warning }
    }
    try { $S.App.LogAction("Created application '$name' from JSON") } catch { }
    return $true
}

function Invoke-SamCreateInSccm {
    param($Selected)
    $targets = @(Get-SamTargetRows $global:SamActCreate ${function:Test-SamCanCreate} $Selected)
    if (-not $targets.Count) { return }

    $check = @($targets | ForEach-Object { [pscustomobject]@{ Key = $_.AppName; Base = $_.BaseName; Version = $_.JsonVersion } })
    $allowed = @(Confirm-SamNoNewerVersion -Items $check -Action 'create')
    $targets = @($targets | Where-Object { $allowed -contains $_.AppName })
    if (-not $targets.Count) { return }
    $lines = $targets | ForEach-Object { '{0}   (folder: {1})' -f $_.AppName, $(if ($_.Config.Application.FolderPath) { $_.Config.Application.FolderPath } else { 'root' }) }
    $code = Get-SamCreateCommandText -Configs @($targets | ForEach-Object { Read-SamAppConfig $_.JsonPath })
    if (-not (Confirm-SamBatch 'Create in SCCM' "Create these applications in site $($global:SAM.Settings.SiteCode)?" $lines -Code $code)) { return }

    $n = 0; $ok = 0
    foreach ($r in $targets) {
        $n++; Set-SamProgress $n $targets.Count 'Create'
        Write-SamLog "[$($r.AppName)] Creating in SCCM"
        $cfg = Read-SamAppConfig $r.JsonPath
        if (Measure-SamStep "Create: $($r.AppName)" { New-SamSccmAppFromConfig -Config $cfg }) { $ok++ }
    }
    Write-SamLog "Create finished: $ok of $($targets.Count) succeeded" -Level Success
    Invoke-SamAfterSccmChange
}
