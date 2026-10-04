@echo off
title Gem Manager Daemon

set "SCRIPT_PATH=C:\GemManagerPS"

:: Enable ANSI color escape sequences in cmd.exe
for /f "tokens=2 delims=]" %%a in ('%SystemRoot%\System32\chcp.com') do set "ORIGINAL_CP=%%a"
chcp 65001 >nul

:: Define ANSI color codes
set "ESC="
set "CYAN=%ESC%[96m"
set "GREEN=%ESC%[92m"
set "YELLOW=%ESC%[93m"
set "RED=%ESC%[91m"
set "RESET=%ESC%[0m"

cls
echo %CYAN%==========================================%RESET%
echo %GREEN%      Starting Gem Manager Daemon         %RESET%
echo %CYAN%==========================================%RESET%
echo.

cd %SCRIPT_PATH%
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "Start-GemManager.ps1" -Daemon

echo.
echo %YELLOW%------------------------------------------%RESET%
echo %RED%      Gem Manager Daemon Stopped.         %RESET%
echo %YELLOW%------------------------------------------%RESET%
echo.

pause

:: Restore original code page on exit
chcp %ORIGINAL_CP:>nul