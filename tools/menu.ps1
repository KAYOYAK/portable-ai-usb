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

# 读一个选择。stdin 被重定向时（管道、计划任务、自动化测试）：
#   PowerShell 5.1 的 Read-Host 会抛 "PowerShell 处于非交互模式"，
#   在 $ErrorActionPreference="Stop" 下直接把整个脚本带走 —— 表现是菜单
#   渲染一次就没了。这里改成显式读一行，读不到才返回 $null。
function Read-Choice([string]$Prompt) {
    try {
        if ([Console]::IsInputRedirected) {
            $line = [Console]::In.ReadLine()
            if ($null -eq $line) { return $null }
            return $line.Trim()
        }
    } catch { return $null }
    try { return (Read-Host $Prompt).Trim() } catch { return $null }
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
    Write-Host "    [10] 选择使用哪个模型  (models\ 下有多个时)"
    Write-Host "    [11] 测一下这支 U 盘的速度  (看看要等多久)"
    Write-Host "    [12] 启动  -  不用 mmap  (慢盘卡顿时用, 占内存)"
    Write-Host ""
    Write-Host "    [0]  退出"
    Write-Host ""
    Write-Host "  ============================================================"
}

# 注意：这里一律直接写 & $Launcher -Param value，不要包一层
#   function Invoke-Launcher { param([string[]]$ExtraArgs) & $Launcher @ExtraArgs }
# 再用 Invoke-Launcher @('-Bench') 调用。
# 数组 splat 是**按位置**传参，不是按名字：@('-Bench') 会把字符串 "-Bench"
# 当成第一个位置参数的值，绑到 $Backend 上，$Bench 永远是 $False ——
# 表现就是选 [11] 却启动了一个服务器。写死参数名则静态可查、不可能错。

# [10] 换模型：把选择写进 models\当前模型.txt，launcher.ps1 下次读它。
# 写纯文本而不是改脚本，是为了让 U 盘在只读介质、或用户没装编辑器的情况下也能换模型。
function Select-Model {
    Clear-Safe
    $dirModels = Join-Path $Root 'models'
    $pickFile  = Join-Path $dirModels '当前模型.txt'

    Write-Host ""
    Write-Host "  ============================================================"
    Write-Host "    选择使用哪个模型"
    Write-Host "  ============================================================"
    Write-Host ""

    if (-not (Test-Path $dirModels)) {
        Write-Host "  [错误] 找不到 $dirModels" -ForegroundColor Red
        Write-Host ""; Pause-Safe; return
    }

    $models = @(Get-ChildItem $dirModels -Filter '*.gguf' -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notlike 'mmproj-*' } |
                Sort-Object Length -Descending)
    if ($models.Count -eq 0) {
        Write-Host "  [错误] models\ 里没有 .gguf 模型文件" -ForegroundColor Red
        Write-Host ""; Pause-Safe; return
    }

    $current = ''
    if (Test-Path $pickFile) {
        $current = Get-Content $pickFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if ($current) { $current = $current.Trim() }
    }

    for ($i = 0; $i -lt $models.Count; $i++) {
        $mark = ''
        if ($models[$i].Name -eq $current) { $mark = '   <- 当前' }
        Write-Host ("    [{0}]  {1}   ({2:N2} GB){3}" -f ($i + 1), $models[$i].Name, ($models[$i].Length / 1GB), $mark)
    }
    Write-Host ""
    Write-Host "    [a]  自动  (每次用体积最大的那个)"
    Write-Host "    [0]  返回"
    Write-Host ""
    Write-Host "  ============================================================"

    $sel = Read-Choice "   请选择"
    if ($null -eq $sel) { return }

    if ($sel -eq 'a' -or $sel -eq 'A') {
        Remove-Item $pickFile -Force -ErrorAction SilentlyContinue
        Write-Host ""
        Write-Host "  已改为自动：下次启动用 models\ 里体积最大的模型。" -ForegroundColor Green
        Write-Host ""; Pause-Safe; return
    }

    $idx = 0
    if (-not [int]::TryParse($sel, [ref]$idx)) { return }
    if ($idx -lt 1 -or $idx -gt $models.Count) { return }

    $chosen = $models[$idx - 1]
    try {
        [System.IO.File]::WriteAllText($pickFile, $chosen.Name + "`r`n", (New-Object System.Text.UTF8Encoding $false))
    } catch {
        Write-Host "  [错误] 写不进 $pickFile ：$($_.Exception.Message)" -ForegroundColor Red
        Write-Host ""; Pause-Safe; return
    }
    Write-Host ""
    Write-Host "  已选定：$($chosen.Name)" -ForegroundColor Green
    Write-Host "  下次双击 启动AI.bat 就用它。" -ForegroundColor Green
    Write-Host ""; Pause-Safe
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
    $opt = Read-Choice "   请选择"
    if ($null -eq $opt) { exit 0 }        # stdin 已关闭（非交互运行）时直接退出

    switch ($opt) {
        "1" { & $Launcher -Backend cuda   -Ctx 32768 -Ngl 99 }
        "2" { & $Launcher -Backend cuda   -Ctx 65536 -Ngl 99 }
        "3" { & $Launcher -Backend cuda   -Ctx 8192  -Ngl 99 }
        "4" { & $Launcher -Backend vulkan -Ngl 99 }
        "5" { & $Launcher -Backend cpu    -Ngl 0 -Ctx 8192 }
        "6" {
            & $Launcher -Probe
            Write-Host ""
            Pause-Safe
        }
        "7" {
            Clear-Safe
            & $Launcher -Stop
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
        "10" { Select-Model }
        "11" {
            Clear-Safe
            # 测速不启动引擎；结果用来告诉人"预计要等多久"
            & $Launcher -Bench
        }
        "12" {
            # 兜底：慢盘上 mmap 按需分页会卡，改成整块读进内存。
            # launcher 自己会检查内存装不装得下，装不下会改回 auto 并说明原因。
            & $Launcher -LoadMode none
        }
        "0" { exit 0 }
        "q" { exit 0 }
        default { }
    }

    # 选项 1-5 会进入 launcher 的等待循环，正常不会回到这里
}
