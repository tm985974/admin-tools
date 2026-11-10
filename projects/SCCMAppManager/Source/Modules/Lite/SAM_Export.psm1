# SAM_Export.psm1   (LITE TIER)
#
# Export an SCCM application to a pipeline JSON (ported from v8.4).
# The JSON records its site: top-level "SiteCode" and ExportedFrom.SCCMSite.
# File name: <AppBaseName>_<SITE>.json - unless the pipeline already has a JSON
# for that application in this site, which is then updated (backup in _Backup).

function Get-SamXmlArg {
    param($ArgList, [string]$ArgName)
    foreach ($a in @($ArgList)) {
        if ($a -and $a.GetAttribute('Name') -eq $ArgName) { return $a.InnerText }
    }
    return $null
}

function Export-SamAppToJson {
    param([string]$AppName)
    $S = $global:SAM

    $data = Invoke-SamCM {
        $a = Measure-SamStep '  Get-CMApplication (full object)' { Get-CMApplication -Name $AppName -ErrorAction Stop }
        $d = Measure-SamStep '  Get-CMDeploymentType' { Get-CMDeploymentType -ApplicationName $AppName -ErrorAction Stop | Select-Object -First 1 }
        [pscustomobject]@{ App = $a; DT = $d }
    }
    $app = $data.App; $dtObj = $data.DT
    if (-not $app)   { Write-SamLog "  Application not found: $AppName" -Level Error; return $null }
    if (-not $dtObj) { Write-SamLog '  No deployment type found' -Level Error; return $null }

    $dtXml = [xml]$dtObj.SDMPackageXML
    $inst  = $dtXml.AppMgmtDigest.DeploymentType.Installer
    $cd    = $inst.CustomData
    $installCmd   = [string]$cd.InstallCommandLine
    $uninstallCmd = [string]$cd.UninstallCommandLine
    $repairCmd    = [string]$cd.RepairCommandLine
    $contentLoc   = [string]$inst.Contents.Content.Location
    $iArgs = @($inst.InstallAction.Args.Arg)

    $execCtx = Get-SamXmlArg $iArgs 'ExecutionContext'
    $ib = switch ($execCtx) { 'User' { 'InstallForUser' } 'Any' { 'InstallForSystemIfResourceIsDeviceOtherwiseInstallForUser' } default { 'InstallForSystem' } }
    $logon = switch (Get-SamXmlArg $iArgs 'RequiresLogOn') { 'true' { 'OnlyWhenUserLoggedOn' } 'false' { 'OnlyWhenNoUserLoggedOn' } default { 'WhetherOrNotUserLoggedOn' } }
    $uiMode = Get-SamXmlArg $iArgs 'UserInteractionMode'
    if (-not $uiMode) { $uiMode = if ((Get-SamXmlArg $iArgs 'RequiresUserInteraction') -eq 'true') { 'Normal' } else { 'Hidden' } }
    $reboot = Get-SamXmlArg $iArgs 'PostInstallBehavior'
    if (-not $reboot) { $reboot = 'BasedOnExitCode' }
    $maxTime = Get-SamXmlArg $iArgs 'MaxExecuteTime'
    $estTime = Get-SamXmlArg $iArgs 'ExecuteTime'

    $detScript = $null; $detLang = 'PowerShell'
    if ($inst.DetectAction) {
        $dArgs = @($inst.DetectAction.Args.Arg)
        $detScript = Get-SamXmlArg $dArgs 'ScriptBody'
        $detLang = switch (Get-SamXmlArg $dArgs 'ScriptType') { '1' { 'VBScript' } '2' { 'JavaScript' } default { 'PowerShell' } }
    }
    if (-not $detScript) {
        try {
            $clauses = Measure-SamStep '  Get-CMDeploymentTypeDetectionClause' { Invoke-SamCM { Get-CMDeploymentTypeDetectionClause -InputObject $dtObj -ErrorAction Stop } }
            foreach ($c in @($clauses)) { if ($c.ScriptText) { $detScript = $c.ScriptText; break } }
        } catch { }
    }
    if (-not $detScript) { Write-SamLog '  No detection SCRIPT found (MSI/registry/file detection is not supported by Create).' -Level Warning }

    $productCode = $null
    if ($uninstallCmd -match $global:SamGuidPattern) { $productCode = $Matches[0] }

    $installer = $null; $topFiles = @()
    if ($contentLoc) {
        $installer = Measure-SamStep '  Analyse content folder' { Find-SamPrimaryInstaller -Folder $contentLoc }
        try { $topFiles = @([IO.Directory]::GetFiles($contentLoc) | ForEach-Object { [IO.Path]::GetFileName($_) }) } catch { }
        if ($installer -and $installer.Type -eq 'MSI' -and -not $productCode) { $productCode = Get-SamMsiProductCode $installer.FullPath }
    }

    $keywords = @(); $publisher = $null; $owner = $null; $contact = $null
    if ($app.SDMPackageXML) {
        try {
            $ax = [xml]$app.SDMPackageXML
            $keywords = @($ax.GetElementsByTagName('Tag') | ForEach-Object { $_.InnerText.Trim() } | Where-Object { $_ } | Select-Object -Unique)
            $pubs = $ax.GetElementsByTagName('Publisher'); if ($pubs.Count) { $publisher = $pubs[0].InnerText.Trim() }
            $own = $ax.GetElementsByTagName('Owners')
            if ($own.Count) { $u = @($own[0].ChildNodes | Where-Object { $_.LocalName -eq 'User' }) | Select-Object -First 1; if ($u) { $owner = $u.GetAttribute('Id') } }
            $con = $ax.GetElementsByTagName('Contacts')
            if ($con.Count) { $u = @($con[0].ChildNodes | Where-Object { $_.LocalName -eq 'User' }) | Select-Object -First 1; if ($u) { $contact = $u.GetAttribute('Id') } }
        }
        catch { Write-SamLog "  Could not parse application XML: $($_.Exception.Message)" -Level Warning }
    }

    $split   = Split-SamAppNameVersion ([string]$app.LocalizedDisplayName) ([string]$app.SoftwareVersion)
    $base    = $split.Base
    $version = if ($app.SoftwareVersion) { [string]$app.SoftwareVersion } else { $split.Version }
    $folder  = $S.Cache.AppFolder[[string]$app.ModelName]

    $iconLocation = $null
    if ($S.Settings.IconsPath) {
        foreach ($ext in @('.ico', '.png', '.jpg')) {
            $candidate = [IO.Path]::Combine($S.Settings.IconsPath, $base + $ext)
            if ([IO.File]::Exists($candidate)) { $iconLocation = $candidate; break }
        }
        if (-not $iconLocation) {
            $iconLocation = [IO.Path]::Combine($S.Settings.IconsPath, $base + '.ico')
            Write-SamLog "  No icon found for '$base' in $($S.Settings.IconsPath)" -Level Warning
        }
    }

    $ibNum = @{ InstallForSystem = '0'; InstallForSystemIfResourceIsDeviceOtherwiseInstallForUser = '1'; InstallForUser = '2' }[$ib]
    $rbNum = @{ BasedOnExitCode = '0'; NoAction = '1'; ForceReboot = '2'; ProgramReboot = '3' }[$reboot]
    $lgNum = @{ OnlyWhenNoUserLoggedOn = '0'; OnlyWhenUserLoggedOn = '1'; WhetherOrNotUserLoggedOn = '2' }[$logon]

    return [ordered]@{
        ConfigVersion = '1.2'
        ConfigType    = 'SCCM Application Configuration'
        SiteCode      = $S.Settings.SiteCode
        ExportDate    = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        ExportedBy    = $env:USERNAME
        ExportedFrom  = [ordered]@{ SCCMSite = $S.Settings.SiteCode; SiteServer = $S.Settings.SiteServer; Environment = $S.Settings.EnvLabel }
        Application   = [ordered]@{
            Name            = $app.LocalizedDisplayName
            LocalizedName   = $app.LocalizedDisplayName
            SoftwareVersion = $app.SoftwareVersion
            Publisher       = $publisher
            Description     = $app.LocalizedDescription
            Keywords        = $keywords
            IconLocation    = $iconLocation
            ReleaseDate     = $(if ($app.DateCreated) { $app.DateCreated.ToString('yyyy-MM-dd') } else { $null })
            Owner           = $owner
            SupportContact  = $contact
            FolderPath      = $folder
            Metadata        = [ordered]@{
                CI_ID            = $app.CI_ID
                ModelName        = $app.ModelName
                DateCreated      = $(if ($app.DateCreated) { $app.DateCreated.ToString('yyyy-MM-dd HH:mm:ss') } else { $null })
                DateLastModified = $(if ($app.DateLastModified) { $app.DateLastModified.ToString('yyyy-MM-dd HH:mm:ss') } else { $null })
            }
        }
        DeploymentType = [ordered]@{
            DeploymentTypeName      = $dtObj.LocalizedDisplayName
            Technology              = $dtObj.Technology
            InstallCommand          = $installCmd
            UninstallCommand        = $uninstallCmd
            RepairCommand           = $repairCmd
            ContentLocation         = $contentLoc
            InstallationBehavior    = [ordered]@{ Type = $ib;     NumericValue = $ibNum }
            RebootBehavior          = [ordered]@{ Type = $reboot; NumericValue = $rbNum }
            LogonRequirement        = [ordered]@{ Type = $logon;  NumericValue = $lgNum }
            UserInteraction         = [ordered]@{ Mode = $uiMode; RequiresInteraction = (Get-SamXmlArg $iArgs 'RequiresUserInteraction') }
            ExecutionTime           = [ordered]@{ MaximumMinutes = $maxTime; EstimatedMinutes = $(if ([int]$estTime -gt 0) { $estTime } else { $null }) }
            InstallExecutionContext = $execCtx
            DetectionMethod         = [ordered]@{
                Type           = $(if ($detScript) { 'Script' } else { 'Unknown' })
                ScriptLanguage = $detLang
                ScriptText     = $detScript
                ScriptLength   = $(if ($detScript) { $detScript.Length } else { 0 })
            }
            ProductCode             = $productCode
            InstallerFiles          = [ordered]@{
                PrimaryFile = $(if ($installer) { $installer.Name } else { $null })
                PrimaryType = $(if ($installer) { $installer.Type } else { $null })
                AllFiles    = $topFiles
            }
        }
        PathConfiguration = [ordered]@{
            CurrentContentPath = $contentLoc
            BaseUNCPath        = $S.Settings.RepositoryPath
            PathPattern        = '{BaseUNCPath}\{AppBaseName}\{Version}\'
            AppBaseName        = $base
            CurrentVersion     = $version
        }
        VersionPatterns = [ordered]@{
            VersionRegex     = '\d+\.\d+(\.\d+)?(\.\d+)?'
            VersionInName    = [bool]$split.Version
            ExtractedVersion = $split.Version
        }
        Notes = @(
            "Exported from SCCM application: $($app.LocalizedDisplayName) (site $($S.Settings.SiteCode))"
            'Local layout: <LocalRoot>\<AppBaseName>_<SITE>.json and <LocalRoot>\<AppBaseName>\<Version>\'
            'Repository layout: {BaseUNCPath}\{AppBaseName}\{Version}\'
            'Icon is looked up as <IconsPath>\<AppBaseName>.ico|.png|.jpg'
        )
    }
}

# Where an export for this base name goes: the existing JSON of this site, else <Base>_<SITE>.json.
function Get-SamJsonTargetPath {
    param([string]$Root, [string]$BaseName, [string]$SiteCode)
    if ($Root -eq [string]$global:SAM.Settings.LocalRootResolved -and $SiteCode -eq [string]$global:SAM.Settings.SiteCode) {
        foreach ($r in $global:SAM.Rows) { if ($r.BaseName -eq $BaseName -and -not $r.Error) { return $r.JsonPath } }
    }
    $safe = $BaseName -replace '[\\/:*?"<>|]', '_'
    return [IO.Path]::Combine($Root, ('{0}_{1}.json' -f $safe, $SiteCode))
}

function Save-SamExportedConfig {
    param($Config)
    $root = [string]$global:SAM.Settings.LocalRootResolved
    $base = [string]$Config.PathConfiguration.AppBaseName
    $path = Get-SamJsonTargetPath -Root $root -BaseName $base -SiteCode ([string]$Config.SiteCode)
    $file = [IO.Path]::GetFileName($path)
    if ([IO.File]::Exists($path)) {
        $ans = [System.Windows.Forms.MessageBox]::Show((Get-SamOwnerForm), "$file already exists.`r`n`r`nOverwrite it? (A backup is kept in _Backup.)", 'Overwrite JSON', 'YesNo', 'Question')   # not-a-command: overwrite question
        if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) { Write-SamLog "  Kept existing $file"; return $null }
        Backup-SamJson $path
    }
    [IO.File]::WriteAllText($path, ($Config | ConvertTo-Json -Depth 12), (New-Object Text.UTF8Encoding($false)))
    Write-SamLog "  Saved $path" -Level Success
    $appFolder = [IO.Path]::Combine($root, ($base -replace '[\\/:*?"<>|]', '_'))
    if (-not [IO.Directory]::Exists($appFolder)) { [void][IO.Directory]::CreateDirectory($appFolder); Write-SamLog "  Created folder $appFolder" }
    return $path
}

function Invoke-SamExportApps {
    param($AppNames)
    if (-not (Test-SamLocalRoot)) { return }
    $names = @(@($AppNames) | Where-Object { $_ })
    if (-not $names.Count) { Write-SamLog 'Select one or more applications first.' -Level Warning; return }
    $code = Get-SamCmCode -Note 'Read-only in SCCM: each application and its deployment type are read, then written as <Local Root>\<AppBaseName>_<SITE>.json (an existing file is asked about and backed up to _Backup).' -Lines @(
        $names | ForEach-Object { 'Get-CMApplication -Name ' + (Format-SamCode ([string]$_)) + ' | Select-Object -ExpandProperty SDMPackageXML   # -> JSON' })
    if (-not (Confirm-SamBatch 'Export to JSON' "Export these application(s) to $($global:SAM.Settings.LocalRootResolved) ?" $names -Code $code -Kind Read)) { return }
    $i = 0; $saved = 0
    foreach ($n in $names) {
        $i++; Set-SamProgress $i $names.Count 'Export'
        Write-SamLog "[$n] Exporting"
        $cfg = Measure-SamStep "Export: $n" { Export-SamAppToJson -AppName $n }
        if ($cfg -and (Save-SamExportedConfig $cfg)) { $saved++ }
    }
    Write-SamLog "Export finished: $saved of $($names.Count) saved" -Level Success
    if ($saved) { Invoke-SamPipelineScan }
}
