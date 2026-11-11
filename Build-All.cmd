@echo off
rem Build-All.cmd -- builds every tool in projects\: each tool's <Name>Dev.exe and,
rem with the passwords you type once at the start, its <Name>Lite.exe (the sealed
rem build to hand out; the same passwords for every tool - press Enter at the
rem first password prompt to build without Lite EXEs). Close the tools first: a
rem running EXE cannot be replaced. ToolBox does the same with a window:
rem Developer tab > Build all.

setlocal
set "ROOT=%~dp0"
set "SRC=%ROOT%template\Source\Build-App.cs"
set "OUT=%ROOT%Build\Build-App.exe"
set "CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if not exist "%CSC%" set "CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe"
if not exist "%CSC%" (
    echo csc.exe not found under %WINDIR%\Microsoft.NET. .NET Framework 4.x is required.
    pause
    exit /b 1
)
if not exist "%SRC%" (
    echo Not found: %SRC%
    pause
    exit /b 1
)
if not exist "%ROOT%Build" mkdir "%ROOT%Build"

echo Compiling Build-App.exe ...
"%CSC%" /nologo /target:exe /optimize+ /out:"%OUT%" /reference:System.IO.Compression.dll /reference:System.IO.Compression.FileSystem.dll /reference:System.Web.Extensions.dll "%SRC%"
if errorlevel 1 (
    echo.
    echo Build-App.exe could not be compiled (see above^).
    pause
    exit /b 1
)

"%OUT%" -All "%ROOT%projects" %*
exit /b %ERRORLEVEL%
