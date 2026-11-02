#Requires -Version 5.1
<#
.SYNOPSIS
    Builds the project: compiles Build-App.cs into Build-App.exe and runs it.
    Same as Build-App.cmd, for machines where PowerShell scripts may run.

.DESCRIPTION
    The builder itself is Build-App.cs (compiled to Build-App.exe), so a project
    can also be built where scripts are blocked: double-click Build-App.cmd, or
    run the Build-App.exe that the developer EXE writes beside itself.

    Build-App.exe, run from the project's source folder:
      - makes the Update folder (default place for update zips) if missing
      - packs the source and compiles the DEVELOPER build  <ExeName>.exe
        (names from AppIdentity.json, version from VERSION.txt)
      - builds <ExeName>Lite.exe, the sealed TEST build (admin "a", user "u")

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
    [string]$OutputExe = '',   # defaults to .\<ExeName>.exe beside this script
    [switch]$NoLite            # skip <ExeName>Lite.exe
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path $MyInvocation.MyCommand.Path -Parent
$Src  = Join-Path $Root 'Build-App.cs'
$Exe  = Join-Path $Root 'Build-App.exe'
if (-not (Test-Path $Src)) { throw "Build-App.cs not found at: $Src" }

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
