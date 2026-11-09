# AdminTools.psm1 -- shared helpers for the repo tools (Windows PowerShell 5.1 and PowerShell 7).
# Uses the same hash rule as TEMPLATE_FILES.txt: SHA-256 of the UTF-8 text with LF line endings and no BOM.

$script:RepoRoot = Split-Path -Parent $PSScriptRoot

function Get-RepoRoot { $script:RepoRoot }
function Get-TemplateRoot { Join-Path $script:RepoRoot 'template' }

function Get-ProjectRoots {
    param([string[]]$Name)
    $all = Get-ChildItem -Path (Join-Path $script:RepoRoot 'projects') -Directory | Sort-Object Name
    if ($Name -and -not ($Name -contains 'all')) {
        foreach ($n in $Name) {
            if (-not ($all | Where-Object { $_.Name -eq $n })) {
                throw "No project folder 'projects/$n'. Projects: $(($all | ForEach-Object Name) -join ', ')"
            }
        }
        $all = $all | Where-Object { $Name -contains $_.Name }
    }
    $all | ForEach-Object { $_.FullName }
}

function Get-NormalizedHash {
    param([Parameter(Mandatory)][string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $start = 0
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $start = 3 }
    # Drop every CR that comes right before an LF (CRLF -> LF), byte for byte.
    $out = New-Object System.IO.MemoryStream ($bytes.Length)
    for ($i = $start; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -eq 13 -and ($i + 1) -lt $bytes.Length -and $bytes[$i + 1] -eq 10) { continue }
        $out.WriteByte($bytes[$i])
    }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash($out.ToArray()) } finally { $sha.Dispose() }
    -join ($hash | ForEach-Object { $_.ToString('x2') })
}

function Read-TemplateManifest {
    # Returns an ordered list of @{ Hash; File } from a TEMPLATE_FILES.txt.
    param([Parameter(Mandatory)][string]$Root)
    $path = Join-Path $Root 'TEMPLATE_FILES.txt'
    if (-not (Test-Path $path)) { throw "Missing $path" }
    foreach ($line in [System.IO.File]::ReadAllLines($path)) {
        $t = $line.Trim().TrimStart([char]0xFEFF)
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $parts = $t -split '\s+', 2
        [pscustomobject]@{ Hash = $parts[0].ToLowerInvariant(); File = $parts[1] }
    }
}

function Test-ManifestFiles {
    # Compares the files under $Root with the manifest entries. Returns one object per problem.
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)]$Manifest)
    foreach ($e in $Manifest) {
        $p = Join-Path $Root $e.File
        if (-not (Test-Path $p)) { [pscustomobject]@{ File = $e.File; Problem = 'missing' }; continue }
        if ((Get-NormalizedHash $p) -ne $e.Hash) { [pscustomobject]@{ File = $e.File; Problem = 'changed' } }
    }
}

function Get-TextFile {
    param([Parameter(Mandatory)][string]$Path)
    ([System.IO.File]::ReadAllText($Path)).TrimStart([char]0xFEFF).Trim()
}

function ConvertTo-Version { param([string]$Text) [version]($Text.Trim()) }

function Get-ChangelogEntries {
    # Parses "vX.Y.Z (date)  title" headings; returns @{ Version; Date; Title; Body }.
    param([Parameter(Mandatory)][string]$Path)
    $entries = @(); $cur = $null
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        if ($line -match '^v(\d+\.\d+\.\d+)\s+\((\d{4}-\d\d-\d\d)\)\s*(.*)$') {
            if ($cur) { $entries += $cur }
            $cur = [pscustomobject]@{ Version = [version]$Matches[1]; Date = $Matches[2]; Title = $Matches[3].Trim(); Body = New-Object System.Collections.Generic.List[string] }
        } elseif ($cur) { $cur.Body.Add($line) }
    }
    if ($cur) { $entries += $cur }
    $entries
}

function Write-Utf8NoBom {
    # Writes text with CRLF line endings and no BOM (how the project files are kept on Windows).
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)
    $t = ($Text -replace "`r`n", "`n") -replace "`n", "`r`n"
    [System.IO.File]::WriteAllText($Path, $t, (New-Object System.Text.UTF8Encoding $false))
}

function Write-Finding {
    # Prints a line and, inside GitHub Actions, an annotation.
    param([ValidateSet('error', 'warning', 'notice')][string]$Level, [string]$Message)
    if ($env:GITHUB_ACTIONS -eq 'true') { Write-Host "::$Level::$Message" }
    else {
        $color = @{ error = 'Red'; warning = 'Yellow'; notice = 'Gray' }[$Level]
        Write-Host ("  [{0}] {1}" -f $Level.ToUpper(), $Message) -ForegroundColor $color
    }
}

Export-ModuleMember -Function *
