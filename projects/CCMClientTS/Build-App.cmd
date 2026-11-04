@echo off
rem Build-App.cmd -- AppTemplate builder for machines where PowerShell scripts
rem may not run. Compiles Build-App.cs (beside this file) into Build-App.exe with
rem the .NET Framework's csc.exe, then runs it: it builds the developer EXE and
rem its Lite test EXE from this source folder.
rem Arguments are passed on to Build-App.exe:  -Output path  -NoLite  -NoPause
rem Template-owned: identical in every project.

setlocal
set "ROOT=%~dp0"
set "CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if not exist "%CSC%" set "CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe"
if not exist "%CSC%" (
    echo csc.exe not found under %WINDIR%\Microsoft.NET. .NET Framework 4.x is required.
    pause
    exit /b 1
)
if not exist "%ROOT%Build-App.cs" (
    echo Build-App.cs not found in %ROOT%
    pause
    exit /b 1
)

echo Compiling Build-App.exe ...
"%CSC%" /nologo /target:exe /optimize+ /out:"%ROOT%Build-App.exe" /reference:System.IO.Compression.dll /reference:System.IO.Compression.FileSystem.dll /reference:System.Web.Extensions.dll "%ROOT%Build-App.cs"
if errorlevel 1 (
    echo.
    echo Build-App.exe could not be compiled (see above^). If Build-App.exe is open, close it.
    pause
    exit /b 1
)

"%ROOT%Build-App.exe" -Root "%ROOT%." %*
exit /b %ERRORLEVEL%
