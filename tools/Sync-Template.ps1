<#
.SYNOPSIS
  Brings projects up to the template version in template\ (the repo version of Update Template).

.DESCRIPTION
  For each project: the files template\TEMPLATE_FILES.txt lists replace the project's engine
  files, engine files the template dropped are deleted, TEMPLATE_FILES.txt and
  TEMPLATE_VERSION.txt are copied, VERSION.txt gets the next patch number and CHANGELOG.txt an
  "Engine synced vA -> vB" entry. Project-owned files are never touched. Nothing is committed:
  review with "git diff", then commit the template change and the syncs together.

      powershell -ExecutionPolicy Bypass -File tools\Sync-Template.ps1                 # every project
      ... -Project ADUserLookup,PDubPaste
      ... -DryRun                                                                       # report only

  A project is skipped, with the reason, when:
    - its template-owned files differ from its own TEMPLATE_FILES.txt (local engine edits)
    - it is already on the template version
    - the step is a contract change: a new major.minor, or a "Contract:" note in a template
      CHANGELOG entry newer than the project's template version. Adapt the project files as
      the notes say, then run again with -AcceptContract.
#>
[CmdletBinding()]
param(
    [string[]]$Project = @('all'),
    [switch]$DryRun,
    [switch]$AcceptContract
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AdminTools.psm1') -Force

$t = Get-TemplateRoot
$tVersion = Get-TextFile (Join-Path $t 'VERSION.txt')
$tManifest = @(Read-TemplateManifest $t)
$bad = @(Test-ManifestFiles -Root $t -Manifest $tManifest)
if ($bad.Count) { throw "template\TEMPLATE_FILES.txt does not match the template files ($($bad[0].File) $($bad[0].Problem)). Run tools\Update-TemplateManifest.ps1 first." }
$tEntries = @(Get-ChangelogEntries (Join-Path $t 'CHANGELOG.txt'))
$tTitle = ($tEntries | Where-Object { $_.Version -eq [version]$tVersion } | Select-Object -First 1).Title
$today = (Get-Date).ToString('yyyy-MM-dd')
$synced = 0

foreach ($root in Get-ProjectRoots -Name $Project) {
    $name = Split-Path $root -Leaf
    $pTv = Get-TextFile (Join-Path $root 'TEMPLATE_VERSION.txt')
    $from = [version]$pTv; $to = [version]$tVersion

    if ($from -ge $to) { Write-Host "${name}: already on template $pTv - skipped"; continue }
    $drift = @(Test-ManifestFiles -Root $root -Manifest @(Read-TemplateManifest $root))
    if ($drift.Count) {
        Write-Host "${name}: SKIPPED - local engine edits: $(($drift | ForEach-Object { "$($_.File) ($($_.Problem))" }) -join ', '). Move them into template\ or revert them." -ForegroundColor Yellow
        continue
    }
    $contract = @()
    if ($from.Major -ne $to.Major -or $from.Minor -ne $to.Minor) { $contract += "new major.minor version ($pTv -> $tVersion)" }
    foreach ($e in ($tEntries | Where-Object { $_.Version -gt $from -and $_.Version -le $to })) {
        $notes = @($e.Body | Where-Object { $_ -match '^\s*Contract\s*:' })
        if ($notes.Count) { $contract += "v$($e.Version): $(($notes | ForEach-Object { $_.Trim() }) -join ' ')" }
    }
    if ($contract.Count -and -not $AcceptContract) {
        Write-Host "${name}: SKIPPED - contract change, adapt the project first, then use -AcceptContract:" -ForegroundColor Yellow
        $contract | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
        continue
    }

    $old = @{}; foreach ($e in (Read-TemplateManifest $root)) { $old[$e.File] = $e.Hash }
    $new = @{}; foreach ($e in $tManifest) { $new[$e.File] = $e.Hash }
    $replaced = @($tManifest | Where-Object { $old.ContainsKey($_.File) -and $old[$_.File] -ne $_.Hash } | ForEach-Object File)
    $added = @($tManifest | Where-Object { -not $old.ContainsKey($_.File) } | ForEach-Object File)
    $removed = @($old.Keys | Where-Object { -not $new.ContainsKey($_) } | Sort-Object)

    $pVersion = [version](Get-TextFile (Join-Path $root 'VERSION.txt'))
    $next = "{0}.{1}.{2}" -f $pVersion.Major, $pVersion.Minor, ($pVersion.Build + 1)
    Write-Host ("{0}: template {1} -> {2}, v{3} -> v{4}: {5} replaced, {6} added, {7} removed" -f $name, $pTv, $tVersion, $pVersion, $next, $replaced.Count, $added.Count, $removed.Count)
    foreach ($f in $replaced) { Write-Host "    MODIFY $f" }
    foreach ($f in $added) { Write-Host "    ADD    $f" }
    foreach ($f in $removed) { Write-Host "    DELETE $f" }
    if ($DryRun) { continue }

    foreach ($f in ($replaced + $added)) {
        $dest = Join-Path $root $f
        $dir = Split-Path $dest -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
        Copy-Item -LiteralPath (Join-Path $t $f) -Destination $dest -Force
    }
    foreach ($f in $removed) { $p = Join-Path $root $f; if (Test-Path $p) { Remove-Item -LiteralPath $p -Force } }
    foreach ($f in 'TEMPLATE_FILES.txt', 'TEMPLATE_VERSION.txt') { Copy-Item -LiteralPath (Join-Path $t $f) -Destination (Join-Path $root $f) -Force }

    Write-Utf8NoBom -Path (Join-Path $root 'VERSION.txt') -Text "$next`n"
    $clPath = Join-Path $root 'CHANGELOG.txt'
    $cl = [System.Collections.Generic.List[string]]([System.IO.File]::ReadAllLines($clPath))
    $at = 0; while ($at -lt $cl.Count -and $cl[$at] -notmatch '^v\d+\.\d+\.\d+\s') { $at++ }
    $entry = @(
        "v$next ($today)  Engine synced v$pTv -> v$tVersion",
        "  Changed : AppTemplate engine v$pTv -> v$tVersion (Sync-Template): $($replaced.Count) file(s) replaced, $($added.Count) added, $($removed.Count) removed.",
        "  Note    : template v$tVersion  $tTitle"
    )
    if ($contract.Count) { $entry += "  Note    : Contract change accepted: $($contract -join '; ')" }
    $entry += ''
    $cl.InsertRange($at, [string[]]$entry)
    Write-Utf8NoBom -Path $clPath -Text (($cl -join "`n") + "`n")
    $synced++
}

if ($DryRun) { Write-Host "Dry run - nothing changed." }
else { Write-Host "$synced project(s) synced. Review with 'git diff', then commit." }
