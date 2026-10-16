<#
================================================================
  portable-ai-usb  ·  自检.ps1
================================================================
  检查这支 U 盘是否完整、是否能在这台电脑上跑起来。
  只读，不修改任何东西。
================================================================
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Continue"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$Root = Split-Path -Parent $PSScriptRoot
$pass = 0; $fail = 0; $warn = 0

function Head($t) {
    Write-Host ""
    Write-Host ("=" * 66) -ForegroundColor DarkCyan
    Write-Host ("  " + $t) -ForegroundColor Cyan
    Write-Host ("=" * 66) -ForegroundColor DarkCyan
}
function P($t) { $script:pass++; Write-Host "  [OK]   $t" -ForegroundColor Green }
function F($t) { $script:fail++; Write-Host "  [缺失] $t" -ForegroundColor Red }
function W($t) { $script:warn++; Write-Host "  [注意] $t" -ForegroundColor Yellow }
function I($t) { Write-Host "         $t" -ForegroundColor DarkGray }

Head "portable-ai-usb  ·  环境自检"
Write-Host "  位置 : $Root"

# ---------------- 1. 文件完整性 ----------------
Write-Host ""
Write-Host "  ── 文件 ──" -ForegroundColor Yellow

$need = @("launcher.ps1", "启动AI.bat", "高级选项.bat", "使用说明.txt")
foreach ($f in $need) {
    if (Test-Path (Join-Path $Root $f)) { P $f } else { F $f }
}

# 模型
$dirModels = Join-Path $Root "models"
$models = @()
if (Test-Path $dirModels) {
    $models = @(Get-ChildItem $dirModels -Filter "*.gguf" -File -ErrorAction SilentlyContinue)
}
if ($models.Count -gt 0) {
    foreach ($m in $models) { P ("模型 {0}  ({1:N2} GB)" -f $m.Name, ($m.Length / 1GB)) }
    if ($models.Count -gt 1) { W "有 $($models.Count) 个模型，启动器只会用最大的那个" }
} else { F "models\ 里没有 .gguf 模型" }

# 引擎
$runtimeDlls = @("vcruntime140.dll", "vcruntime140_1.dll", "msvcp140.dll", "msvcp140_1.dll")
$dirLlama = Join-Path $Root "llama.cpp"
$engineNames = @{ cuda13 = "NVIDIA CUDA"; vulkan = "Vulkan（AMD/Intel/老NVIDIA）"; cpu = "纯 CPU（兜底）" }
$haveEngine = @()
foreach ($k in @("cuda13", "vulkan", "cpu")) {
    $d = Join-Path $dirLlama $k
    $exe = Join-Path $d "llama-server.exe"
    if (Test-Path $exe) {
        $sz = [math]::Round((Get-ChildItem $d -File -Recurse | Measure-Object Length -Sum).Sum / 1MB, 1)
        $n = @(Get-ChildItem $d -File -Recurse).Count
        P ("引擎 {0,-7} ({1})  {2} MB / {3} 文件" -f $k, $engineNames[$k], $sz, $n)
        $haveEngine += $k

        $miss = @($runtimeDlls | Where-Object { -not (Test-Path (Join-Path $d $_)) })
        if ($miss.Count -gt 0) { W "   $k 缺运行库：$($miss -join ', ')" }
        if (-not (Test-Path (Join-Path $d "ggml-cpu-haswell.dll"))) {
            I "$k 没看到 ggml-cpu-*.dll（如果这台机器 CPU 较老，可能起不来）"
        }
    } else { I "引擎 $k 未安装" }
}
if ($haveEngine.Count -eq 0) { F "一个引擎都没有 —— 先跑 tools\准备U盘.ps1" }

# 目录结构
foreach ($f in @("docs", "tools")) {
    if (Test-Path (Join-Path $Root $f)) { P "$f\" } else { W "$f\ 不在（不影响运行）" }
}

# ---------------- 2. 介质 ----------------
Write-Host ""
Write-Host "  ── 介质 ──" -ForegroundColor Yellow

$rootPath = [System.IO.Path]::GetPathRoot($Root)
if ($rootPath) {
    $letter = $rootPath.TrimEnd('\:')
    $vol = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue
    if ($vol) {
        $freeGB = [math]::Round($vol.SizeRemaining / 1GB, 1)
        I "盘符 $letter`  文件系统 $($vol.FileSystem)  剩余 $freeGB GB"
        if ($vol.FileSystem -eq "FAT32") { F "FAT32 单文件上限 4 GB —— 模型放不下" }
        else { P "文件系统 $($vol.FileSystem) 没问题" }
        if ($vol.DriveType -eq 'Removable') { P "可移动介质（会随身带走）" }
        else { W "不是可移动介质 —— 确认一下这是不是你要做的那支 U 盘" }
    }
}

# ---------------- 3. 本机硬件 ----------------
Write-Host ""
Write-Host "  ── 本机硬件 ──" -ForegroundColor Yellow

$cores = 0
try { $cores = (Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfCores -Sum).Sum } catch { }
$ramGB = 0
try { $ramGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1) } catch { }
$gpus = @()
try { $gpus = @(Get-CimInstance Win32_VideoController | ForEach-Object { $_.Name }) } catch { }

I "CPU $cores 核 / 内存 $ramGB GB"
foreach ($g in $gpus) { I "显卡 $g" }

$modelGB = if ($models.Count -gt 0) { [math]::Round($models[0].Length / 1GB, 2) } else { 0 }
if ($modelGB -gt 0 -and $ramGB -gt 0) {
    if ($ramGB -ge ($modelGB + 1.5)) { P "内存充足（模型 $modelGB GB）" }
    elseif ($ramGB -ge $modelGB)     { W "内存偏紧：模型 $modelGB GB / 内存 $ramGB GB —— 会走 mmap 换页，速度会掉" }
    else                              { W "内存不足：模型 $modelGB GB / 内存 $ramGB GB —— 能跑但会很慢" }
}

# ---------------- 4. 逐套引擎实测 ----------------
Write-Host ""
Write-Host "  ── 逐套引擎实测（--list-devices）──" -ForegroundColor Yellow

foreach ($k in $haveEngine) {
    $exe = Join-Path $dirLlama "$k\llama-server.exe"
    $out = $null
    try {
        Push-Location (Split-Path $exe -Parent)
        $out = & $exe --list-devices 2>&1 | Out-String
        Pop-Location
    } catch { try { Pop-Location } catch {}; $out = "$($_.Exception.Message)" }

    $dev = @()
    if ($out -match '(?im)^\s*(CUDA|Vulkan|Metal|OpenCL)\d*\s*:\s*(.+)$') {
        $dev = @([regex]::Matches($out, '(?im)^\s*(CUDA|Vulkan|Metal|OpenCL)\d*\s*:\s*(.+)$') |
                 ForEach-Object { "$($_.Groups[1].Value): $($_.Groups[2].Value.Trim())" })
    }
    if ($dev.Count -gt 0) { P "$k 可用 -> $($dev -join ' | ')" }
    elseif ($k -eq "cpu") { P "$k 可用（CPU 引擎本来就没有设备列表）" }
    else { W "$k 在这台电脑上没有可用设备" }
}

# ---------------- 5. 启动器探测 ----------------
Write-Host ""
Write-Host "  ── 启动器自动选型 ──" -ForegroundColor Yellow
$launcher = Join-Path $Root "launcher.ps1"
if (Test-Path $launcher) {
    try {
        $probe = & powershell -NoProfile -ExecutionPolicy Bypass -File $launcher -Probe 2>&1 | Out-String
        $probe.Trim().Split("`n") | Where-Object { $_.Trim() } | ForEach-Object { I $_.TrimEnd() }
        if ($probe -match '后端 = (\w+)') { P "启动器会选择：$($Matches[1])" }
    } catch { W "探测失败：$($_.Exception.Message)" }
} else { F "launcher.ps1 不存在" }

# ---------------- 汇总 ----------------
Write-Host ""
Write-Host ("=" * 66) -ForegroundColor DarkCyan
Write-Host ("  通过 $pass 项   注意 $warn 项   缺失 $fail 项") -ForegroundColor $(if ($fail -gt 0) { "Red" } elseif ($warn -gt 0) { "Yellow" } else { "Green" })
Write-Host ("=" * 66) -ForegroundColor DarkCyan
if ($fail -eq 0) {
    Write-Host "  这支 U 盘是完整的。插到别的电脑上双击「启动AI.bat」即可。" -ForegroundColor Green
} else {
    Write-Host "  有缺失项。跑 tools\准备U盘.ps1 可以补齐。" -ForegroundColor Yellow
}
Write-Host ""
