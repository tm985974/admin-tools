@echo off
rem Build-App.cmd -- AppTemplate builder for machines where PowerShell scripts
rem may not run. Compiles Source\Build-App.cs into Build\Build-App.exe with the
rem .NET Framework's csc.exe, then runs it: it builds the developer EXE and its
rem Lite test EXE beside this file, from the Source folder.
rem Arguments are passed on to Build-App.exe:  -Output path  -NoLite  -NoPause
rem Template-owned: identical in every project. (A pre-1.1 flat folder, with
rem Build-App.cs beside this file, still builds.)

setlocal
set "ROOT=%~dp0"
set "SRC=%ROOT%Source\Build-App.cs"
set "OUT=%ROOT%Build\Build-App.exe"
if not exist "%SRC%" (
    set "SRC=%ROOT%Build-App.cs"
    set "OUT=%ROOT%Build-App.exe"
)
set "CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if not exist "%CSC%" set "CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe"
if not exist "%CSC%" (
    echo csc.exe not found under %WINDIR%\Microsoft.NET. .NET Framework 4.x is required.
    pause
    exit /b 1
)
if not exist "%SRC%" (
    echo Build-App.cs not found in %ROOT%Source
    pause
    exit /b 1
)
for %%I in ("%OUT%") do if not exist "%%~dpI" mkdir "%%~dpI"

echo Compiling Build-App.exe ...
"%CSC%" /nologo /target:exe /optimize+ /out:"%OUT%" /reference:System.IO.Compression.dll /reference:System.IO.Compression.FileSystem.dll /reference:System.Web.Extensions.dll "%SRC%"
if errorlevel 1 (
    echo.
    echo Build-App.exe could not be compiled (see above^). If Build-App.exe is open, close it.
    pause
    exit /b 1
)

"%OUT%" -Root "%ROOT%." %*
exit /b %ERRORLEVEL%
