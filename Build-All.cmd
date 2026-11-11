@echo off
rem Build-All.cmd -- builds every tool in projects\ with its own Build-App.cmd,
rem one after another, and lists the ones that failed. Close the tools first:
rem a running EXE cannot be replaced. (ToolBox does the same with a window:
rem Developer tab > Build all.)

setlocal enabledelayedexpansion
set "ROOT=%~dp0"
set "FAILED="
set /a COUNT=0
for /d %%P in ("%ROOT%projects\*") do (
    if exist "%%P\Build-App.cmd" (
        echo.
        echo ==================== %%~nxP ====================
        call "%%P\Build-App.cmd" -NoPause < NUL
        if errorlevel 1 (set "FAILED=!FAILED! %%~nxP") else (set /a COUNT+=1)
    )
)
echo.
echo ===================================================
if defined FAILED (
    echo Built: !COUNT!    FAILED:!FAILED!
    echo Scroll up for the errors. Is that tool still running?
) else (
    echo All !COUNT! tools built.
)
echo.
pause
