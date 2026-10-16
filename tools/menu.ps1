<#
================================================================
  portable-ai-usb  ·  高级选项菜单
================================================================
  为什么菜单在 PowerShell 里而不是在 .bat 里：
  cmd.exe 解析批处理时按本地 ANSI 码页逐字节切分，中文
  UTF-8 字节可能撞进 GBK 双字节区间，导致解析器错位、把
  菜单行拆成乱码命令。把中文界面放到 PowerShell 里可以
  彻底绕开这个问题；.bat 只留纯 ASCII 的引导行。
================================================================
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# tools\ 的上一级就是 U 盘根目录
$Here     = $PSScriptRoot
if (-not $Here) { $Here = Split-Path -Parent $MyInvocation.MyCommand.Definition }
$Root     = Split-Path -Parent $Here.TrimEnd('\')
$Launcher = Join-Path $Root 'launcher.ps1'
$SelfTest = Join-Path $Here '自检.ps1'

function Clear-Safe {
    # 非交互场景（无控制台 / stdin 被重定向）下 Clear-Host 会抛异常
    try { Clear-Host } catch { }
}

function Pause-Safe {
    try { Pause } catch { }
}

function Show-Menu {
    Clear-Safe
    Write-Host ""
    Write-Host "  ============================================================"
    Write-Host "    U盘 AI 便携版  -  高级选项"
    Write-Host "  ============================================================"
    Write-Host ""
    Write-Host "    [1]  NVIDIA  -  32K 上下文   (最常用)"
    Write-Host "    [2]  NVIDIA  -  64K 上下文   (长文档 / 长对话)"
    Write-Host "    [3]  NVIDIA  -   8K 上下文   (小显存机)"
    Write-Host ""
    Write-Host "    [4]  AMD / Intel 显卡  (Vulkan)"
    Write-Host "    [5]  纯 CPU 模式  (任何电脑都能跑, 速度慢)"
    Write-Host ""
    Write-Host "    [6]  仅检测硬件, 不启动"
    Write-Host "    [7]  停止本 U 盘的 AI"
    Write-Host "    [8]  打开 AI 网页界面"
    Write-Host "    [9]  环境自检  (U盘文件是否齐全)"
    Write-Host ""
    Write-Host "    [0]  退出"
    Write-Host ""
    Write-Host "  ============================================================"
}

function Invoke-Launcher {
    param([string[]]$ExtraArgs)
    & $Launcher @ExtraArgs
}

if (-not (Test-Path $Launcher)) {
    Write-Host ""
    Write-Host "  [错误] 找不到 launcher.ps1，U 盘可能不完整。" -ForegroundColor Red
    Write-Host "         期望位置：$Launcher"
    Write-Host ""
    Pause-Safe
    exit 1
}

while ($true) {
    Show-Menu
    $opt = Read-Host "   请选择 [0-9]"
    if ($null -eq $opt) { exit 0 }        # stdin 已关闭（非交互运行）时直接退出
    $opt = $opt.Trim()

    switch ($opt) {
        "1" { Invoke-Launcher @('-Backend','cuda','-Ctx','32768','-Ngl','99') }
        "2" { Invoke-Launcher @('-Backend','cuda','-Ctx','65536','-Ngl','99') }
        "3" { Invoke-Launcher @('-Backend','cuda','-Ctx','8192','-Ngl','99') }
        "4" { Invoke-Launcher @('-Backend','vulkan','-Ngl','99') }
        "5" { Invoke-Launcher @('-Backend','cpu','-Ngl','0','-Ctx','8192') }
        "6" {
            Invoke-Launcher @('-Probe')
            Write-Host ""
            Pause-Safe
        }
        "7" {
            Clear-Safe
            Invoke-Launcher @('-Stop')
            Write-Host ""
            Pause-Safe
        }
        "8" { Start-Process "http://127.0.0.1:8080" }
        "9" {
            Clear-Safe
            if (Test-Path $SelfTest) { & $SelfTest } else { Write-Host "  [缺失] 找不到 $SelfTest" -ForegroundColor Red }
            Write-Host ""
            Pause-Safe
        }
        "0" { exit 0 }
        "q" { exit 0 }
        default { }
    }

    # 选项 1-5 会进入 launcher 的等待循环，正常不会回到这里
}
