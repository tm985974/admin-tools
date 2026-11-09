<#
.SYNOPSIS
  Checks the template and every project for manifest errors and engine drift.

.DESCRIPTION
  Runs on every push (GitHub Actions) and can be run locally:
      powershell -ExecutionPolicy Bypass -File tools\Test-Template.ps1

  Errors (exit code 1):
    - template\TEMPLATE_FILES.txt lists a hash that does not match the file (stale manifest:
      run tools\Update-TemplateManifest.ps1), or VERSION / TEMPLATE_VERSION / CHANGELOG disagree
    - a project's template-owned files differ from its own TEMPLATE_FILES.txt (local engine edit)
    - a project claims the current template version but carries a different manifest
    - a project is on a newer template than template\ , or AppIdentity.json is missing/invalid
    - two projects share an ExeName or AppDataFolder
  Warnings:
    - a project is behind the template (tools\Sync-Template.ps1 brings it up)
    - an engine-looking file in template\Modules\Base is not in the manifest

  -Strict turns "behind the template" into an error.
#>
[CmdletBinding()]
param([switch]$Strict)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AdminTools.psm1') -Force

$errors = 0; $warnings = 0
function Err([string]$m) { $script:errors++; Write-Finding error $m }
function Warn([string]$m) { $script:warnings++; Write-Finding warning $m }

# Files in Modules/Base that every project owns itself (see TEMPLATE_FILES.txt header).
$projectOwnedBase = @('Modules/Base/UI_Register-Tabs.psm1', 'Modules/Base/UI_Tab_Overview.psm1')

# ---- template ---------------------------------------------------------------
$t = Get-TemplateRoot
Write-Host "template"
$tVersion = Get-TextFile (Join-Path $t 'VERSION.txt')
$tTemplateVersion = Get-TextFile (Join-Path $t 'TEMPLATE_VERSION.txt')
if ($tVersion -ne $tTemplateVersion) { Err "template: VERSION.txt ($tVersion) and TEMPLATE_VERSION.txt ($tTemplateVersion) differ" }

$header = [System.IO.File]::ReadAllLines((Join-Path $t 'TEMPLATE_FILES.txt')) | Select-Object -First 3
$hm = [regex]::Match(($header -join "`n"), 'AppTemplate v(\d+\.\d+\.\d+)')
if ($hm.Success -and $hm.Groups[1].Value -ne $tVersion) { Err "template: TEMPLATE_FILES.txt header says v$($hm.Groups[1].Value), VERSION.txt says $tVersion" }

$top = Get-ChangelogEntries (Join-Path $t 'CHANGELOG.txt') | Select-Object -First 1
if (-not $top -or $top.Version -ne [version]$tVersion) { Err "template: newest CHANGELOG.txt entry is v$($top.Version), VERSION.txt says $tVersion" }

$tManifest = @(Read-TemplateManifest $t)
foreach ($p in (Test-ManifestFiles -Root $t -Manifest $tManifest)) {
    Err "template: $($p.File) is $($p.Problem) compared with TEMPLATE_FILES.txt (stale manifest? run tools\Update-TemplateManifest.ps1)"
}
$listed = $tManifest | ForEach-Object File
Get-ChildItem (Join-Path $t 'Modules/Base') -File | ForEach-Object {
    $rel = 'Modules/Base/' + $_.Name
    if (($listed -notcontains $rel) -and ($projectOwnedBase -notcontains $rel)) {
        Warn "template: $rel is not in TEMPLATE_FILES.txt, so it will never reach the projects"
    }
}
$tManifestText = ($tManifest | ForEach-Object { "$($_.Hash)  $($_.File)" }) -join "`n"
Write-Host ("  v{0}, {1} template-owned files" -f $tVersion, $tManifest.Count)

# ---- projects ---------------------------------------------------------------
$rows = @(); $exeNames = @{}; $dataFolders = @{}
foreach ($root in Get-ProjectRoots) {
    $name = Split-Path $root -Leaf
    $state = 'ok'
    try {
        $id = [System.IO.File]::ReadAllText((Join-Path $root 'AppIdentity.json')) | ConvertFrom-Json
        foreach ($k in 'AppName', 'ExeName', 'AppDataFolder') { if (-not $id.$k) { throw "no $k" } }
        if ($id.ExeName -ne $name) { Warn "${name}: folder name differs from ExeName '$($id.ExeName)'" }
        if ($exeNames.ContainsKey($id.ExeName)) { Err "${name}: ExeName '$($id.ExeName)' is also used by $($exeNames[$id.ExeName])" } else { $exeNames[$id.ExeName] = $name }
        if ($dataFolders.ContainsKey($id.AppDataFolder)) { Err "${name}: AppDataFolder '$($id.AppDataFolder)' is also used by $($dataFolders[$id.AppDataFolder]) (they would share environments and logs)" } else { $dataFolders[$id.AppDataFolder] = $name }
    } catch { Err "${name}: AppIdentity.json is missing or invalid ($($_.Exception.Message))"; $state = 'error' }

    $v = Get-TextFile (Join-Path $root 'VERSION.txt')
    $tv = Get-TextFile (Join-Path $root 'TEMPLATE_VERSION.txt')
    $top = Get-ChangelogEntries (Join-Path $root 'CHANGELOG.txt') | Select-Object -First 1
    if (-not $top -or $top.Version -ne [version]$v) { Err "${name}: newest CHANGELOG.txt entry is v$($top.Version), VERSION.txt says $v"; $state = 'error' }

    $m = @(Read-TemplateManifest $root)
    $drift = @(Test-ManifestFiles -Root $root -Manifest $m)
    foreach ($p in $drift) { Err "${name}: template-owned $($p.File) is $($p.Problem) (engine edits belong in template\, then Sync-Template)" }
    if ($drift.Count) { $state = 'drift' }

    $cmp = (ConvertTo-Version $tv).CompareTo((ConvertTo-Version $tVersion))
    if ($cmp -gt 0) { Err "${name}: on template $tv, newer than template\ ($tVersion)"; $state = 'error' }
    elseif ($cmp -lt 0) {
        $msg = "${name}: on template $tv, template is $tVersion (run tools\Sync-Template.ps1 -Project $name)"
        if ($Strict) { Err $msg } else { Warn $msg }
        if ($state -eq 'ok') { $state = 'behind' }
    } else {
        $mText = ($m | ForEach-Object { "$($_.Hash)  $($_.File)" }) -join "`n"
        if ($mText -ne $tManifestText) { Err "${name}: claims template $tv but its TEMPLATE_FILES.txt differs from template\"; $state = 'error' }
    }
    $rows += [pscustomobject]@{ Project = $name; Version = $v; Template = $tv; Status = $state }
}

$rows | Format-Table -AutoSize | Out-String | Write-Host
Write-Host ("{0} error(s), {1} warning(s)" -f $errors, $warnings)
if ($env:GITHUB_STEP_SUMMARY) {
    $md = @("### Template v$tVersion", '', '| Project | Version | Template | Status |', '|---|---|---|---|')
    $md += $rows | ForEach-Object { "| $($_.Project) | $($_.Version) | $($_.Template) | $($_.Status) |" }
    $md += '', "$errors error(s), $warnings warning(s)"
    Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value ($md -join "`n")
}
if ($errors) { exit 1 }
