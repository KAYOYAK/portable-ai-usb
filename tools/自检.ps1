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
$mmprojFiles = @()
if (Test-Path $dirModels) {
    # mmproj-*.gguf 是视觉投影文件、不是模型本体，必须排除 ——
    # 启动器就是这么排除的。两边不一致的话，下面拿 $models[0] 得出的内存结论就是错的。
    # 同时按体积倒序：启动器默认挑最大的那个，这里必须和它选同一个。
    $mmprojFiles = @(Get-ChildItem $dirModels -Filter "mmproj-*.gguf" -File -ErrorAction SilentlyContinue)
    $models = @(Get-ChildItem $dirModels -Filter "*.gguf" -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notlike "mmproj-*" } |
                Sort-Object Length -Descending)
}
$pickFile = Join-Path $dirModels "当前模型.txt"
$pickName = ""
if (Test-Path $pickFile) {
    $pickName = (Get-Content $pickFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue)
    if ($pickName) { $pickName = $pickName.Trim() } else { $pickName = "" }
}
# 启动器会优先用 当前模型.txt 指定的那个；没指定才用体积最大的。
$defaultModel = $null
if ($pickName) { $defaultModel = $models | Where-Object { $_.Name -eq $pickName } | Select-Object -First 1 }
if (-not $defaultModel -and $models.Count -gt 0) { $defaultModel = $models[0] }

if ($models.Count -gt 0) {
    foreach ($m in $models) {
        $mark = if ($defaultModel -and $m.Name -eq $defaultModel.Name) { "   <- 启动时用这个" } else { "" }
        P ("模型 {0}  ({1:N2} GB){2}" -f $m.Name, ($m.Length / 1GB), $mark)
    }
    if ($pickName -and -not ($models | Where-Object { $_.Name -eq $pickName })) {
        W "当前模型.txt 写的是「$pickName」，但 models\ 里没有这个文件 —— 会退回用最大的那个"
    }
} else { F "models\ 里没有 .gguf 模型" }
if ($mmprojFiles.Count -gt 0) {
    I ("视觉投影 {0}  ({1:N2} GB) —— 启动时会自动打开视觉能力" -f $mmprojFiles[0].Name, ($mmprojFiles[0].Length / 1GB))
}

# 模型完整性。准备U盘.ps1 下载时验过一次哈希，但那个值不落盘就随着脚本结束一起
# 消失了 —— 用户几个月后怀疑文件坏了，手上没有任何基准可以比。所以它会把每个
# 模型的实际哈希写进 models\校验.txt，这里读那份清单来复查。
# 大小不符最省事；大小相符但哈希不同，才是真正隐蔽的那种损坏（镜像无视 Range
# 拼出来的文件、以及存储介质自己烂掉，都会是这个样子）。
$manifest = Join-Path $dirModels "校验.txt"
if ($models.Count -gt 0) {
    if (-not (Test-Path $manifest)) {
        W "没有 models\校验.txt —— 没法确认模型文件是否完好（跑一次 tools\准备U盘.ps1 会生成）"
    } else {
        $known = @{}
        foreach ($ln in @(Get-Content $manifest -Encoding UTF8 -ErrorAction SilentlyContinue)) {
            if ($ln -match '^\s*([0-9a-fA-F]{64})\s+(\d+)\s+(.+?)\s*$') {
                $known[$Matches[3]] = @{ Hash = $Matches[1].ToLower(); Size = [long]$Matches[2] }
            }
        }
        foreach ($m in $models) {
            $k = $known[$m.Name]
            if (-not $k) {
                W "$($m.Name) 不在校验清单里 —— 清单是旧的，重跑 tools\准备U盘.ps1 可以补上"
                continue
            }
            if ($k.Size -ne $m.Length) {
                F ("{0} 大小不对：清单写 {1} 字节，实际 {2} 字节 —— 没下完整或被换过" -f $m.Name, $k.Size, $m.Length)
                continue
            }
            Write-Host ("         正在算 {0} 的哈希（{1:N2} GB，要几十秒）..." -f $m.Name, ($m.Length / 1GB)) -ForegroundColor DarkGray
            $swHash = [Diagnostics.Stopwatch]::StartNew()
            try {
                $h = (Get-FileHash $m.FullName -Algorithm SHA256 -ErrorAction Stop).Hash.ToLower()
                $swHash.Stop()
                if ($h -eq $k.Hash) {
                    P ("{0} 完好（sha256 一致，耗时 {1:N0} 秒）" -f $m.Name, $swHash.Elapsed.TotalSeconds)
                } else {
                    F ("{0} 坏了：清单 {1}...，实际 {2}... —— 重新拷一份过来" -f $m.Name, $k.Hash.Substring(0, 12), $h.Substring(0, 12))
                }
            } catch {
                F "$($m.Name) 读不出来：$($_.Exception.Message)"
            }
        }
    }
}

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

$modelGB = if ($defaultModel) { [math]::Round($defaultModel.Length / 1GB, 2) } else { 0 }
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
