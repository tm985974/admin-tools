<#
.SYNOPSIS
  Builds an update zip for the developer EXE's Update button from what changed in git.

.DESCRIPTION
  Collects the files of one project (or template\) that changed since a git ref - by default
  the project's newest tag, e.g. ADUserLookup/v1.2.17 - and zips them with paths from the
  project root. Deleted files become "Delete:" lines in UPDATE.txt. A zip that includes
  _AppLauncher.ps1 gets "Mode: Partial" so it merges instead of replacing everything.
  Use it to update a developer EXE on a machine that has no git checkout.

      powershell -ExecutionPolicy Bypass -File tools\New-UpdateZip.ps1 -Project ADUserLookup
      ... -Project template
      ... -Project PDubPaste -Since PDubPaste/v1.2.0
      ... -Project PDubPaste -Full          # every file: a full source package

  Output: out\<ExeName>_update_v<from>_to_v<to>.zip (out\ is ignored by git).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Project,
    [string]$Since,
    [switch]$Full
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AdminTools.psm1') -Force
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

$repo = Get-RepoRoot
if ($Project -eq 'template') { $root = Get-TemplateRoot; $rel = 'template'; $tagPrefix = 'template' }
else { $root = @(Get-ProjectRoots -Name $Project)[0]; $rel = "projects/$Project"; $tagPrefix = $Project }
$id = [System.IO.File]::ReadAllText((Get-PackageFile $root 'AppIdentity.json')) | ConvertFrom-Json
$version = Get-TextFile (Get-PackageFile $root 'VERSION.txt')

function Invoke-Git { $out = & git -C $repo @args; if ($LASTEXITCODE) { throw "git $args failed" }; $out }

$changed = @(); $deleted = @()
if ($Full) {
    $changed = @(Invoke-Git ls-files -- $rel | ForEach-Object { ConvertTo-PackagePath $_.Substring($rel.Length + 1) })
    $fromLabel = 'full'
} else {
    if (-not $Since) {
        $Since = Invoke-Git tag --list "$tagPrefix/v*" --sort=-v:refname | Select-Object -First 1
        if (-not $Since) { throw "No tag $tagPrefix/v* yet; pass -Since <git ref> or -Full" }
    }
    $fromLabel = 'v' + ($Since -replace '^.*/v', '')
    # Committed changes since the ref plus uncommitted ones in the working tree.
    foreach ($line in (Invoke-Git diff --name-status --no-renames $Since -- $rel)) {
        $parts = $line -split "`t"
        $f = ConvertTo-PackagePath $parts[1].Substring($rel.Length + 1)
        if ($parts[0] -eq 'D') { $deleted += $f } else { $changed += $f }
    }
    foreach ($f in (Invoke-Git ls-files --others --exclude-standard -- $rel)) { $changed += (ConvertTo-PackagePath $f.Substring($rel.Length + 1)) }
}
$changed = @($changed | Sort-Object -Unique)
if (-not $changed.Count -and -not $deleted.Count) { Write-Host "Nothing changed in $rel since $Since."; return }
if (-not $Full -and $changed.Count -and ($changed -notcontains 'VERSION.txt')) {
    Write-Warning "VERSION.txt is not in the update: bump it (and CHANGELOG.txt) so titles and Version History move on."
}

$outDir = Join-Path $repo 'out'
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }
$zipName = if ($Full) { "$($id.ExeName)_v$version.zip" } else { "$($id.ExeName)_update_$($fromLabel)_to_v$version.zip" }
$zipPath = Join-Path $outDir $zipName
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

$directives = @()
if (-not $Full) {
    if ($changed -contains '_AppLauncher.ps1') { $directives += 'Mode: Partial' }
    $directives += $deleted | ForEach-Object { "Delete: $_" }
}

$zip = [System.IO.Compression.ZipFile]::Open($zipPath, 'Create')
try {
    foreach ($f in $changed) {
        # Forward slashes in entry names (Compress-Archive in PowerShell 5.1 writes backslashes).
        [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, (Get-PackageFile $root $f), $f, 'Optimal')
    }
    if ($directives.Count) {
        $entry = $zip.CreateEntry('UPDATE.txt')
        $w = New-Object System.IO.StreamWriter ($entry.Open(), (New-Object System.Text.UTF8Encoding $false))
        try { $w.Write(($directives -join "`r`n") + "`r`n") } finally { $w.Dispose() }
    }
} finally { $zip.Dispose() }

Write-Host "$zipPath"
Write-Host ("  {0} file(s), {1} delete(s) since {2}" -f $changed.Count, $deleted.Count, $(if ($Full) { 'start' } else { $Since }))
$changed | ForEach-Object { Write-Host "    $_" }
$deleted | ForEach-Object { Write-Host "    DELETE $_" }
