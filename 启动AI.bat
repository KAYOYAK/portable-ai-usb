@echo off
rem  This file must stay pure ASCII: cmd.exe reads a .bat in the OEM code page
rem  before chcp takes effect, so non-ASCII bytes here turn into garbage.
rem  < nul : chcp would otherwise drain redirected stdin, and the launcher
rem  would then have nothing left to read.
chcp 65001 >nul < nul
rem  pushd maps a UNC share (\\server\share\...) to a temp drive letter;
rem  cd /d cannot switch to a UNC path at all.
pushd "%~dp0" >nul 2>&1 || cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0launcher.ps1" %*
if errorlevel 1 (
    pause
    exit /b 1
)
