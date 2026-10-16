@echo off
chcp 65001 >nul
title U盘 AI 助手 - 高级选项
cd /d "%~dp0"

:menu
cls
echo.
echo   ============================================================
echo     U盘 AI 助手  -  高级选项
echo   ============================================================
echo.
echo     [1]  NVIDIA 显卡 - 标准       32K上下文  (最常用)
echo     [2]  NVIDIA 显卡 - 大上下文   64K上下文  (长文档/长对话)
echo     [3]  NVIDIA 显卡 - 省显存     8K 上下文  (小显存机)
echo.
echo     [4]  AMD / Intel 显卡 (Vulkan)
echo     [5]  纯 CPU 模式              任何电脑都能跑, 速度慢
echo.
echo     [6]  仅检测硬件, 不启动
echo     [7]  停止本 U 盘的 AI          (不会影响电脑上其它的 llama-server)
echo     [8]  打开 AI 网页界面
echo.
echo     [9]  环境自检                  (U盘文件是否齐全)
echo.
echo     [0]  退出
echo.
echo   ============================================================
set /p opt="   请选择 [0-9]: "

if "%opt%"=="1" goto std
if "%opt%"=="2" goto big
if "%opt%"=="3" goto small
if "%opt%"=="4" goto vk
if "%opt%"=="5" goto cpu
if "%opt%"=="6" goto probe
if "%opt%"=="7" goto stop
if "%opt%"=="8" goto open
if "%opt%"=="9" goto selftest
if "%opt%"=="0" exit /b 0
goto menu

:std
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0launcher.ps1" -Backend cuda -Ctx 32768 -Ngl 99
goto end

:big
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0launcher.ps1" -Backend cuda -Ctx 65536 -Ngl 99
goto end

:small
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0launcher.ps1" -Backend cuda -Ctx 8192 -Ngl 99
goto end

:vk
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0launcher.ps1" -Backend vulkan -Ngl 99
goto end

:cpu
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0launcher.ps1" -Backend cpu -Ngl 0 -Ctx 8192
goto end

:probe
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0launcher.ps1" -Probe
echo.
pause
goto menu

:stop
cls
echo.
echo   正在停止本 U 盘的 AI 引擎...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0launcher.ps1" -Stop
echo.
pause
goto menu

:open
start http://127.0.0.1:8080
goto menu

:selftest
cls
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\自检.ps1"
echo.
pause
goto menu

:end
echo.
pause
exit /b 0
