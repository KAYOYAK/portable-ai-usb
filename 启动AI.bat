@echo off
chcp 65001 >nul
title U盘 AI 助手 - MiMo-V2.6 9B
cd /d "%~dp0"

echo.
echo   ============================================================
echo     U盘 AI 便携版  -  正在检测这台电脑的硬件...
echo   ============================================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0launcher.ps1" %*

if errorlevel 1 (
  echo.
  pause
)
