<#
.SYNOPSIS
  Recomputes every hash in template\TEMPLATE_FILES.txt from the files on disk.

.DESCRIPTION
  Run this after changing any template-owned file and before committing a template
  release, so the manifest can never ship with a stale hash (the AppHost.cs problem
  fixed in v1.0.17, v1.0.20 and v1.0.23). The header's "AppTemplate vX" is set from
  template\VERSION.txt.

      powershell -ExecutionPolicy Bypass -File tools\Update-TemplateManifest.ps1
      ... -Add Modules/Base/Services_New.psm1      # start owning a new engine file
      ... -Remove Modules/Base/Services_Old.psm1   # stop owning one (projects delete it on sync)
#>
[CmdletBinding()]
param([string[]]$Add, [string[]]$Remove)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AdminTools.psm1') -Force

$t = Get-TemplateRoot
$path = Join-Path $t 'TEMPLATE_FILES.txt'
$version = Get-TextFile (Join-Path $t 'VERSION.txt')
$lines = [System.IO.File]::ReadAllLines($path)

# Header = the comment block at the top (everything before the first hash line).
$header = @(); foreach ($l in $lines) { if ($l.Trim() -ne '' -and -not $l.TrimStart().StartsWith('#')) { break }; $header += $l }
$header = $header | ForEach-Object { $_ -replace 'AppTemplate v\d+\.\d+\.\d+', "AppTemplate v$version" }

$files = New-Object System.Collections.Generic.List[string]
foreach ($e in (Read-TemplateManifest $t)) { $files.Add($e.File) }
foreach ($a in $Add) { $a = $a -replace '\\', '/'; if (-not $files.Contains($a)) { $files.Add($a) } }
foreach ($r in $Remove) { [void]$files.Remove(($r -replace '\\', '/')) }

$out = @($header)
$changed = 0
$old = @{}; foreach ($e in (Read-TemplateManifest $t)) { $old[$e.File] = $e.Hash }
foreach ($f in $files) {
    $p = Join-Path $t $f
    if (-not (Test-Path $p)) { throw "template\$f is listed but does not exist" }
    $h = Get-NormalizedHash $p
    if ($old[$f] -ne $h) { $changed++; Write-Host "  updated $f" }
    $out += "$h  $f"
}
Write-Utf8NoBom -Path $path -Text (($out -join "`n") + "`n")
Write-Host ("TEMPLATE_FILES.txt: {0} files, {1} hash(es) changed, version v{2}" -f $files.Count, $changed, $version)
