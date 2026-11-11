#Requires -Version 5.1
<#
.SYNOPSIS
    Builds the project: compiles Build-App.cs into Build-App.exe and runs it.
    Same as Build-App.cmd, for machines where PowerShell scripts may run.

.DESCRIPTION
    The builder itself is Build-App.cs (compiled to Build-App.exe), so a project
    can also be built where scripts are blocked: double-click Build-App.cmd, or
    run the Build-App.exe that the developer EXE writes beside itself.

    Template 1.1 layout: this script lives in <project>\Source; Build-App.exe goes
    to <project>\Build and the EXEs to the project folder. (In a pre-1.1 flat
    folder everything sits together, as before.)

    Build-App.exe:
      - makes the Update folder (default place for update zips) if missing
      - packs the source and compiles the DEVELOPER build  <ExeName>Dev.exe
        (names from AppIdentity.json, version from VERSION.txt)
      - builds <ExeName>Lite.exe, the sealed build to hand out (asks for the
        user / admin passwords; blank = no Lite EXE this time)

    You only need a build for the first build on a machine or for recovery.
    Every other change goes through the developer EXE: Update (an update zip) or
    Update Template (the template's source zip). See README.md.

.NOTES
    Requires: .NET Framework 4.x (csc.exe), Windows PowerShell 5.1.
    If AV quarantines the output EXE, exclude the output folder from real-time
    scanning before building.
#>

[CmdletBinding()]
param(
    [string]$OutputExe = '',   # defaults to <project>\<ExeName>Dev.exe
    [switch]$NoLite            # skip <ExeName>Lite.exe
)

$ErrorActionPreference = 'Stop'
$Here = Split-Path $MyInvocation.MyCommand.Path -Parent
$Src  = Join-Path $Here 'Build-App.cs'
if (-not (Test-Path $Src)) { throw "Build-App.cs not found at: $Src" }
if ((Split-Path $Here -Leaf) -eq 'Source') {
    $Root = Split-Path $Here -Parent                      # template 1.1: <project>\Source
    $Exe  = Join-Path (Join-Path $Root 'Build') 'Build-App.exe'
    New-Item -ItemType Directory -Path (Split-Path $Exe -Parent) -Force | Out-Null
}
else {
    $Root = $Here                                          # pre-1.1 flat folder
    $Exe  = Join-Path $Root 'Build-App.exe'
}

$WinDir = [System.Environment]::GetFolderPath('Windows')
$Csc = Join-Path $WinDir 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $Csc)) { $Csc = Join-Path $WinDir 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path $Csc)) { throw "csc.exe not found under $WinDir\Microsoft.NET. .NET Framework 4.x required." }

Write-Host 'Compiling Build-App.exe ...' -ForegroundColor Cyan
& $Csc /nologo /target:exe /optimize+ "/out:$Exe" /reference:System.IO.Compression.dll `
       /reference:System.IO.Compression.FileSystem.dll /reference:System.Web.Extensions.dll $Src
if ($LASTEXITCODE -ne 0) { throw "Build-App.exe could not be compiled (exit $LASTEXITCODE). If Build-App.exe is open, close it." }

$buildArgs = @('-Root', $Root, '-NoPause')
if ($OutputExe) { $buildArgs += @('-Output', $OutputExe) }
if ($NoLite)    { $buildArgs += '-NoLite' }
& $Exe @buildArgs
exit $LASTEXITCODE
