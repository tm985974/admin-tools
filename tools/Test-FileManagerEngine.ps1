# Test-FileManagerEngine.ps1 -- compiles the File Manager engine and runs it end to end
# on a throw-away test drive (a temporary folder mapped to a free drive letter with subst).
#
#   powershell -ExecutionPolicy Bypass -File tools\Test-FileManagerEngine.ps1
#
# Windows PowerShell 5.1 (the engine's real host). Nothing outside the temporary folder
# is touched; the catalog is a temporary file too. Exit code 0 = every check passed.

param([string]$Root = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
$failures = 0
function Check([bool]$Ok, [string]$What) {
    if ($Ok) { Write-Host "  ok    $What" -ForegroundColor Green }
    else { Write-Host "  FAIL  $What" -ForegroundColor Red; $script:failures++ }
}
function Wait-Job2($Job) {
    while (-not $Job.Finished) { Start-Sleep -Milliseconds 100 }
    foreach ($l in $Job.FullLog()) { Write-Host "        $l" -ForegroundColor DarkGray }
    if ($Job.Failed) { throw "$($Job.Name) failed: $($Job.Error)" }
}
function New-File([string]$Path, [string]$Text, [datetime]$When) {
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Text)
    (Get-Item -LiteralPath $Path).LastWriteTime = $When
}

# ---- compile ----
$psm = Join-Path $Root 'projects\FileManager\Source\Modules\Lite\FM_Engine.psm1'
$text = [System.IO.File]::ReadAllText($psm)
$m = [regex]::Match($text, "(?s)\`$script:FmEngineSource = @'\r?\n(.*?)\r?\n'@")
if (-not $m.Success) { throw "Engine source not found in $psm" }
Write-Host 'Compiling the engine...'
Add-Type -TypeDefinition $m.Groups[1].Value -Language CSharp
Check $true 'engine compiles (C# 5, Add-Type)'

# ---- small units ----
Check ([FileManagerEngine.Wild]::Match('thumbs.db', 'thumbs.db')) 'wildcard: exact'
Check ([FileManagerEngine.Wild]::Match('~$report.docx', '~$*')) 'wildcard: prefix *'
Check (-not [FileManagerEngine.Wild]::Match('photo.jpg', '*.png')) 'wildcard: no match'
Check ([FileManagerEngine.Util]::CodePoints('a' + [char]0xD83D + [char]0xDE00 + 'b') -eq 3) 'code points count a surrogate pair once'

# ---- a test drive ----
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('FmTest_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$data = Join-Path $tmp 'drive'
New-Item -ItemType Directory -Path $data -Force | Out-Null
$used = @([System.IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.Substring(0, 1).ToUpperInvariant() })
$letter = @('Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y') | Where-Object { $used -notcontains $_ } | Select-Object -First 1
if (-not $letter) { throw 'No free drive letter for the test drive.' }
& subst.exe "$($letter):" $data
if ($LASTEXITCODE -ne 0) { throw "subst failed ($LASTEXITCODE)" }
$drive = "$($letter):\"
Write-Host "Test drive $drive -> $data"

$cat = $null
try {
    $old = Get-Date '2004-06-01 10:00'
    $new = Get-Date '2019-03-01 10:00'
    # A and "A copy" are the same folder (different name, newer dates, plus a Thumbs.db).
    New-File "$data\A\photos\1.jpg" ('one' * 1000) $old
    New-File "$data\A\photos\2.jpg" ('two' * 2000) $old
    New-File "$data\A\notes.txt" 'notes' $old
    New-File "$data\A copy\photos\1.jpg" ('one' * 1000) $new
    New-File "$data\A copy\photos\2.jpg" ('two' * 2000) $new
    New-File "$data\A copy\notes.txt" 'notes' $new
    New-File "$data\A copy\photos\Thumbs.db" 'junk' $new
    # C\sub\pics is a copy of A\photos inside a folder that is otherwise unique.
    New-File "$data\C\sub\pics\1.jpg" ('one' * 1000) $new
    New-File "$data\C\sub\pics\2.jpg" ('two' * 2000) $new
    New-File "$data\C\own.txt" 'only here' $new
    # D has the same sizes as A\photos but different content (quick match only).
    New-File "$data\D\x.jpg" ('ONE' * 1000) $new
    New-File "$data\D\y.jpg" ('TWO' * 2000) $new
    New-File "$data\loose.txt" 'a file at the top' $new

    $dbPath = Join-Path $tmp 'catalog\FileManager.db'
    $cat = New-Object FileManagerEngine.Catalog -ArgumentList $dbPath
    Check (Test-Path -LiteralPath $dbPath) "catalog created (hash $($cat.HashAlgorithm))"
    $o = New-Object FileManagerEngine.ScanOptions
    $o.IgnoreFiles = [string[]]@('Thumbs.db', 'desktop.ini')
    $o.IgnoreFolders = [string[]]@('.Trashes')
    $o.ContentCheck = $true
    $cat.Options = $o

    $vol = @($cat.GetVolumes() | Where-Object { $_.Root -eq $drive })
    Check ($vol.Count -eq 1) "test drive is listed ($($vol[0].Display))"

    Write-Host 'Scan + content check + find duplicates...'
    Wait-Job2 ($cat.StartScan($drive, $o))
    $drives = @($cat.GetDrives())
    Check ($drives.Count -eq 1 -and $drives[0].Files -eq 12) "scan found 12 files (Thumbs.db ignored): $($drives[0].Files)"
    $groups = @($cat.GetGroups(100))
    Check ($groups.Count -eq 2) "2 duplicate groups: $($groups.Count)"
    $top = $groups | Where-Object { $_.Name -eq 'A' }
    Check ($null -ne $top -and $top.Confirmed) 'A and "A copy" match by content; A is kept (oldest files)'
    $m1 = @($cat.GetMembers($top.Id))
    Check (($m1 | Where-Object { $_.Role -eq 'Duplicate' }).Path -eq 'A copy') '"A copy" is the duplicate'
    $g2 = $groups | Where-Object { $_.Name -eq 'photos' }
    $m2 = @($cat.GetMembers($g2.Id))
    Check (($m2 | Where-Object { $_.Role -eq 'Keep' }).Path -eq 'A\photos') 'A\photos is kept (inside a kept folder)'
    Check (($m2 | Where-Object { $_.Role -eq 'Duplicate' }).Path -eq 'C\sub\pics') 'C\sub\pics is the duplicate (top-down: A copy\photos is not listed)'

    Write-Host 'Plan + apply...'
    $plan = $cat.BuildPlan($true, $true, [long[]]@($drives[0].Id), $false)
    Write-Host $plan.Script -ForegroundColor DarkGray
    Check ($plan.DupItems -eq 2 -and $plan.CleanItems -eq 4) "plan: 2 duplicates, 4 to _Clean (A, C, D, loose.txt): $($plan.DupItems), $($plan.CleanItems)"
    Wait-Job2 ($cat.StartApply($plan.BatchId))
    Check (Test-Path -LiteralPath "$($drive)_Duplicates\A\A (1)\photos\1.jpg") '"A copy" -> _Duplicates\A\A (1)'
    Check (Test-Path -LiteralPath "$($drive)_Duplicates\A\A (1)_origin.txt") 'origin note written NEXT TO the copy'
    Check (-not (Test-Path -LiteralPath "$($drive)_Duplicates\A\A (1)\_origin.txt")) 'nothing added inside the copy'
    Check (Test-Path -LiteralPath "$($drive)_Duplicates\A\photos\photos (1)\2.jpg") 'C\sub\pics -> _Duplicates\A\photos\photos (1)'
    Check (Test-Path -LiteralPath "$($drive)_Clean\A\photos\1.jpg") 'A -> _Clean\A'
    Check (Test-Path -LiteralPath "$($drive)_Clean\C\own.txt") 'C (unique, minus its duplicate) -> _Clean\C'
    Check (-not (Test-Path -LiteralPath "$($drive)_Clean\C\sub\pics")) 'the duplicate left C before C moved'
    Check (Test-Path -LiteralPath "$($drive)_Clean\loose.txt") 'top-level file -> _Clean'

    Write-Host 'Undo...'
    $bid = $plan.BatchId
    Wait-Job2 ($cat.StartUndo($bid))
    Check (Test-Path -LiteralPath "$data\A copy\photos\1.jpg") '"A copy" is back'
    Check (Test-Path -LiteralPath "$data\C\sub\pics\1.jpg") 'C\sub\pics is back'
    Check (Test-Path -LiteralPath "$data\loose.txt") 'loose.txt is back'
    Check (-not (Test-Path -LiteralPath "$($drive)_Duplicates\A\A (1)_origin.txt")) 'origin note removed on undo'

    Write-Host 'Rescan (keeps earlier hashes), apply again, delete duplicates...'
    Wait-Job2 ($cat.StartScan($drive, $o))
    Check (@($cat.GetDrives())[0].Hashed -ge 10) "content hashes complete after the rescan (earlier ones kept): $(@($cat.GetDrives())[0].Hashed)"
    $plan = $cat.BuildPlan($true, $true, [long[]]@($drives[0].Id), $false)
    Check ($plan.DupItems -eq 2) 'second plan: 2 duplicates'
    Check ($plan.Script -match [regex]::Escape('A (2)')) 'numbers carry on: A (2) (A (1) was used by the undone batch)'
    # tick only C (for _Clean): the duplicate inside C must come along, and nothing else moves
    $acts = @($cat.GetActions($plan.BatchId, 1000))
    $cleanC = @($acts | Where-Object { $_.Kind -eq 'To _Clean' -and $_.Src -like '*:\C' })[0]
    $exp = @($cat.ExpandForMove($plan.BatchId, [long[]]@($cleanC.Id)))
    Check ($exp.Count -eq 2) "ticking C for _Clean also takes the duplicate inside it: $($exp.Count) steps"
    Wait-Job2 ($cat.StartApply($plan.BatchId, [long[]]@($cleanC.Id)))
    Check ((Test-Path -LiteralPath "$($drive)_Clean\C\own.txt") -and (Test-Path -LiteralPath "$($drive)_Duplicates\A\photos\photos (2)\1.jpg")) 'C and its duplicate moved'
    Check (Test-Path -LiteralPath "$data\A copy\notes.txt") 'unticked steps did not run ("A copy" still in place)'
    Check (@($cat.GetActions($plan.BatchId, 1000) | Where-Object { $_.Status -eq 'planned' }).Count -eq 4) 'the other 4 steps are still planned'
    Wait-Job2 ($cat.StartApply($plan.BatchId))
    # change one duplicate after the move: it must NOT be deleted
    $changed = Get-ChildItem -LiteralPath "$($drive)_Duplicates\A\photos" -Directory | Select-Object -First 1
    [System.IO.File]::AppendAllText((Join-Path $changed.FullName '1.jpg'), 'x')
    Wait-Job2 ($cat.StartDeleteDuplicates($plan.BatchId))
    Check (-not (Test-Path -LiteralPath "$($drive)_Duplicates\A\A (2)")) 'verified duplicate deleted'
    Check (Test-Path -LiteralPath $changed.FullName) 'changed duplicate kept (re-check failed as it should)'
    Check (Test-Path -LiteralPath "$($drive)_Clean\A\photos\1.jpg") 'kept copy untouched'
    Check (-not (Test-Path -LiteralPath "$($drive)_Duplicates\A\A (2)_origin.txt")) 'origin note deleted with its copy'

    Write-Host 'Verify copy + remove verified source files...'
    $src = Join-Path $tmp 'src'; $dst = Join-Path $tmp 'dst'
    New-File "$src\a.txt" 'same' $old
    New-File "$src\deep\b.txt" 'same too' $old
    New-File "$src\c.txt" 'different' $old
    New-File "$src\d.txt" 'missing in target' $old
    New-File "$dst\a.txt" 'same' $old
    New-File "$dst\deep\b.txt" 'same too' $old
    New-File "$dst\c.txt" 'DIFFERENT' $old
    $j = $cat.StartVerifyCopy($src, $dst)
    Wait-Job2 $j
    $run = @($cat.GetVerifyRuns(1))[0]
    Check ($run.Ok -eq 2 -and $run.Different -eq 1 -and $run.Missing -eq 1) "verify: 2 ok, 1 different, 1 missing: $($run.Ok), $($run.Different), $($run.Missing)"
    Wait-Job2 ($cat.StartRemoveVerified($run.Id))
    Check (-not (Test-Path -LiteralPath "$src\a.txt") -and -not (Test-Path -LiteralPath "$src\deep")) 'verified files and the emptied folder removed'
    Check ((Test-Path -LiteralPath "$src\c.txt") -and (Test-Path -LiteralPath "$src\d.txt")) 'different and missing files stay'

    Write-Host 'Folder scan, folder plan, check only...'
    Wait-Job2 ($cat.StartScan($drive, $o))   # the remove step above marks the test drive for a rescan (it shares C:'s serial)
    New-File "$data\NewStuff\D2\x.jpg" ('ONE' * 1000) $new
    New-File "$data\NewStuff\D2\y.jpg" ('TWO' * 2000) $new
    New-File "$data\NewStuff\fresh.txt" 'brand new' $new
    $before = @($cat.GetDrives())[0].Files
    Wait-Job2 ($cat.StartScanFolder("$($drive)NewStuff", $o))
    Check (@($cat.GetDrives())[0].Files -eq $before + 3) "folder scan added 3 files and kept the rest of the drive: $before -> $(@($cat.GetDrives())[0].Files)"
    $plan = $cat.BuildPlan($true, $true, [long[]]@(), $false, "$($drive)NewStuff")
    Write-Host $plan.Script -ForegroundColor DarkGray
    Check ($plan.DupItems -eq 1 -and $plan.CleanItems -eq 1) "folder plan: NewStuff\D2 is a duplicate of D, NewStuff goes to _Clean: $($plan.DupItems), $($plan.CleanItems)"
    Wait-Job2 ($cat.StartApply($plan.BatchId))
    Check ((Test-Path -LiteralPath "$($drive)_Clean\NewStuff\fresh.txt") -and (Test-Path -LiteralPath "$($drive)_Duplicates\D\D (1)\x.jpg")) 'folder plan applied'

    $thumb = Join-Path $tmp 'thumb'
    New-File "$thumb\pics\1.jpg" ('one' * 1000) $new
    New-File "$thumb\pics\2.jpg" ('two' * 2000) $new
    New-File "$thumb\new.txt" 'not anywhere else' $new
    $j = $cat.StartCheck($thumb)
    Wait-Job2 $j
    $run = $cat.GetCheck($j.ResultId)
    Check ($run.Files -eq 3 -and $run.HaveFiles -eq 2 -and $run.NewFiles -eq 1) "check: 2 of 3 files found, 1 new: $($run.HaveFiles) of $($run.Files), $($run.NewFiles) new"
    $pics = @($cat.GetCheckRows($j.ResultId, 'folder', 100) | Where-Object { $_.Rel -eq 'pics' })
    Check ($pics.Count -eq 1 -and $pics[0].Status -eq 'Already have it') "pics: already have it ($($pics[0].Matched))"
    $nf = @($cat.GetCheckRows($j.ResultId, 'file', 100))
    Check ($nf.Count -eq 1 -and $nf[0].Rel -eq 'new.txt') 'files not found: new.txt'
    Check ($null -ne $cat.GetWorkflow()) 'workflow status works'

    $csv = Join-Path $tmp 'dups.csv'
    [void]$cat.ExportDuplicatesCsv($csv)
    $cat.ExportHtml((Join-Path $tmp 'report.html'), 100)
    Check ((Test-Path -LiteralPath $csv) -and (Test-Path -LiteralPath (Join-Path $tmp 'report.html'))) 'CSV and HTML exports written'
    $cat.Reset($true)
    Check (@($cat.GetDrives())[0].Files -eq 0 -and @($cat.GetBatches(10)).Count -ge 2) 'Start fresh (keep history): catalog empty, batches kept'
    $cat.Reset($false)
    Check (@($cat.GetDrives()).Count -eq 0 -and @($cat.GetBatches(10)).Count -eq 0) 'Start fresh (everything): catalog and history empty'
}
finally {
    if ($cat) { try { $cat.Close() } catch { } }
    & subst.exe "$($letter):" /d | Out-Null
    try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction Stop } catch { Write-Host "  (left $($tmp): $($_.Exception.Message))" }
}

if ($failures) { Write-Host "$failures check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'All File Manager engine checks passed.' -ForegroundColor Green
