<#
================================================================
  portable-ai-usb  ·  启动器
================================================================
  模型 : MiMo-V2.6-Distill-Qwen-9B (GGUF)
  引擎 : llama.cpp —— CUDA 13 / Vulkan / CPU 自动择一
  用法 : 双击 U 盘根目录的 "启动AI.bat"
  设计 : 所有路径都由 $PSScriptRoot 推导，U 盘插到哪台电脑、
         变成哪个盘符都不影响。
================================================================
#>
[CmdletBinding()]
param(
    [string]$Backend   = "auto",   # auto | cuda13 | vulkan | cpu
    [int]$Port         = 8080,
    [int]$Ctx          = 0,        # 0 = 按显存/内存自动
    [int]$Ngl          = -1,       # -1 = 自动
    [switch]$NoBrowser,
    [string]$ModelName = "",       # 指定 models\ 里的哪个 .gguf；空 = 按约定自动选
                                   # 坑：这个参数不能叫 $Model —— PowerShell 变量名大小写
                                   # 不敏感，会和下面的 $model 变成同一个变量，[string]
                                   # 的类型约束把 FileInfo 强转成字符串，.Name/.FullName 全空。
    [switch]$Probe,                # 只探测环境，不启动
    [switch]$Stop                  # 只停掉"本 U 盘"启动的引擎
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
try { $Host.UI.RawUI.WindowTitle = "U盘 AI 便携版 - MiMo 9B" } catch { }

# ---------------- 路径（全部相对 U 盘） ----------------
$Root = $PSScriptRoot
if (-not $Root) { $Root = Split-Path -Parent $MyInvocation.MyCommand.Definition }
if (-not $Root) { $Root = (Get-Location).Path }
$Root = $Root.TrimEnd('\')

$DirModels = Join-Path $Root "models"
$DirLlama  = Join-Path $Root "llama.cpp"
$DirLog    = Join-Path $Root "logs"
if (-not (Test-Path $DirLog)) { New-Item -ItemType Directory -Force -Path $DirLog | Out-Null }

function Head($t) {
    Write-Host ""
    Write-Host ("=" * 64) -ForegroundColor DarkCyan
    Write-Host ("  " + $t) -ForegroundColor Cyan
    Write-Host ("=" * 64) -ForegroundColor DarkCyan
}

# 判断某个路径是不是在本 U 盘目录下（用来区分"我们的"进程）
function Test-UnderRoot([string]$path) {
    if (-not $path) { return $false }
    return $path.StartsWith($Root + "\", [StringComparison]::OrdinalIgnoreCase)
}

# ---------------- 0. -Stop：只停本 U 盘的引擎 ----------------
# 坑：直接 taskkill /IM llama-server.exe 会把宿主机上"别人"的 llama-server 一起杀掉。
#     这里按可执行文件路径过滤，只动 U 盘目录里的那几个。
if ($Stop) {
    Head "停止本 U 盘的 AI 引擎"
    $killed = 0; $skipped = 0
    $procs = @(Get-Process -Name "llama-server" -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) {
        Write-Host "  没有发现正在运行的 llama-server。" -ForegroundColor DarkGray
    }
    foreach ($p in $procs) {
        $pth = $null
        try { $pth = $p.Path } catch { $pth = $null }   # 别的用户的进程读不到 Path
        if (Test-UnderRoot $pth) {
            try { Stop-Process -Id $p.Id -Force -ErrorAction Stop
                  Write-Host "  已停止 PID $($p.Id)  $pth" -ForegroundColor Green; $killed++ }
            catch { Write-Host "  停止 PID $($p.Id) 失败：$($_.Exception.Message)" -ForegroundColor Yellow }
        } else {
            Write-Host "  跳过 PID $($p.Id)（不属于本 U 盘）：$pth" -ForegroundColor DarkGray
            $skipped++
        }
    }
    Write-Host ""
    Write-Host "  已停止 $killed 个；跳过 $skipped 个不属于本 U 盘的进程。"
    exit 0
}

Head "U盘 AI 便携版  ·  llama.cpp"
Write-Host "  启动位置 : $Root"

# ---------------- 1. 找模型 ----------------
# models\ 里可以放任意多个 .gguf，按下面的顺序决定用哪个：
#   ① 启动参数 -ModelName 指定的文件名
#   ② models\当前模型.txt 里写的文件名（在 高级选项.bat 的 [10] 里改）
#   ③ 都没写 -> 用体积最大的那个
# mmproj-*.gguf 是多模态投影文件，不是模型本体，不参与挑选也不参与比较。
if (-not (Test-Path $DirModels)) { Write-Host "  [错误] 找不到 models 目录" -ForegroundColor Red; Read-Host "  回车退出"; exit 1 }

$allModels = @(Get-ChildItem $DirModels -Filter "*.gguf" -File -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -notlike "mmproj-*" })
if ($allModels.Count -eq 0) { Write-Host "  [错误] models 目录里没有 .gguf 模型文件" -ForegroundColor Red; Read-Host "  回车退出"; exit 1 }

$pickFile = Join-Path $DirModels "当前模型.txt"
$model    = $null
$source   = ""

if ($ModelName) {
    $model = $allModels | Where-Object { $_.Name -eq $ModelName } | Select-Object -First 1
    if (-not $model) {
        Write-Host "  [错误] models 目录里没有叫「$ModelName」的模型。现有的有：" -ForegroundColor Red
        $allModels | Sort-Object Length -Descending | ForEach-Object { Write-Host "         $($_.Name)" }
        Read-Host "  回车退出"; exit 1
    }
    $source = "启动参数 -ModelName 指定"
} elseif (Test-Path $pickFile) {
    $want = Get-Content $pickFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if ($want) { $want = $want.Trim() }
    if ($want) {
        $model = $allModels | Where-Object { $_.Name -eq $want } | Select-Object -First 1
        if ($model) { $source = "models\当前模型.txt 指定" }
        else { Write-Host "  [注意] 当前模型.txt 里写的「$want」在 models\ 里找不到，改回自动选最大的。" -ForegroundColor Yellow }
    }
}

if (-not $model) {
    $model  = $allModels | Sort-Object Length -Descending | Select-Object -First 1
    $source = "自动（体积最大）"
}

$modelGB = [math]::Round($model.Length / 1GB, 2)
$alias   = [IO.Path]::GetFileNameWithoutExtension($model.Name)
Write-Host "  模型     : $($model.Name)" -ForegroundColor Green
Write-Host "  模型大小 : $modelGB GB"
if ($allModels.Count -gt 1) {
    Write-Host "  选择依据 : $source" -ForegroundColor DarkGray
    Write-Host "  可选模型 :" -ForegroundColor DarkGray
    foreach ($m in ($allModels | Sort-Object Length -Descending)) {
        $mark = ""
        if ($m.Name -eq $model.Name) { $mark = "   <- 本次使用" }
        Write-Host ("             {0}  ({1:N2} GB){2}" -f $m.Name, ($m.Length / 1GB), $mark) -ForegroundColor DarkGray
    }
    Write-Host "  换模型   : 打开 高级选项.bat 选 [10]" -ForegroundColor DarkGray
}

# ---------------- 2. 探测硬件 ----------------
$cores = 0
try { $cores = (Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfCores -Sum).Sum } catch { }
if (-not $cores -or $cores -lt 1) { $cores = [Environment]::ProcessorCount }
$threads = [math]::Max(2, $cores)

$ramGB = 0
try { $ramGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1) } catch { }

$gpuNames = @()
try { $gpuNames = @(Get-CimInstance Win32_VideoController -ErrorAction Stop | ForEach-Object { $_.Name }) } catch { }

# 坑：PowerShell 的 -match / -notmatch 对数组返回的是"匹配到的元素"而不是布尔值。
#     双显卡机器上（核显+独显）直接当条件用必翻车。先压成明确的布尔量。
$hasNvidia    = [bool]@($gpuNames | Where-Object { $_ -match '(?i)nvidia' }).Count

$nvVramGB = 0
try {
    $q = & nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>$null
    if ($LASTEXITCODE -eq 0 -and $q) { $nvVramGB = [math]::Round(([double]($q | Select-Object -First 1)) / 1024, 1) }
} catch { }

Write-Host ""
Write-Host "  本机     :  CPU $cores 核 / 内存 $ramGB GB"
if ($gpuNames.Count -gt 0) { Write-Host "  显卡     :  $($gpuNames -join '  |  ')" -ForegroundColor DarkGray }
if ($nvVramGB -gt 0)       { Write-Host "  显存     :  $nvVramGB GB (NVIDIA)" -ForegroundColor DarkGray }

# ---------------- 3. 内存预算（决定后面会不会自动降级） ----------------
# 模型走 mmap：不需要整份塞进内存也能跑，但内存越紧、换页越多、越卡。
$comfortGB = $modelGB + 1.5
$ramTight  = ($ramGB -gt 0) -and ($ramGB -lt $comfortGB)
$ramTiny   = ($ramGB -gt 0) -and ($ramGB -lt ($modelGB + 0.5))

# ---------------- 4. 选后端：逐级降级，能跑 GPU 就别用 CPU ----------------
function Test-GpuDevices([string]$exe) {
    if (-not (Test-Path $exe)) { return $false }
    try {
        $out = & $exe --list-devices 2>&1 | Out-String
        return ($out -match '(?i)(CUDA|Vulkan)\s*\d+\s*:')
    } catch { return $false }
}

$exeTable = [ordered]@{
    cuda13 = Join-Path $DirLlama "cuda13\llama-server.exe"   # CUDA 13.4 —— 新驱动 r580+
    vulkan = Join-Path $DirLlama "vulkan\llama-server.exe"   # AMD / Intel / 老 NVIDIA
    cpu    = Join-Path $DirLlama "cpu\llama-server.exe"      # 兜底，任何 x86-64 都能跑
}

if ($Backend -eq "auto") {
    $order = @("cuda13", "vulkan", "cpu")
    if (-not $hasNvidia) { $order = @("vulkan", "cuda13", "cpu") }
} else {
    $order = switch ($Backend) {
        "cuda"   { @("cuda13") }
        "cuda13" { @("cuda13") }
        "vulkan" { @("vulkan") }
        "cpu"    { @("cpu") }
        default  { @("cuda13", "vulkan", "cpu") }
    }
}

Write-Host ""
Write-Host "  正在探测这台电脑能用的加速方式..." -ForegroundColor DarkYellow
$backend = $null
foreach ($c in $order) {
    $p = $exeTable[$c]
    if (-not (Test-Path $p)) { Write-Host "    $c : U盘上没有这个版本" -ForegroundColor DarkGray; continue }
    if ($c -eq "cpu") {
        $backend = "cpu"; Write-Host "    cpu  : 可用（兜底）" -ForegroundColor DarkGray; break
    }
    if ($c -eq "cuda13" -and -not $hasNvidia) {
        Write-Host "    $c : 这台电脑没有 NVIDIA 显卡" -ForegroundColor DarkGray; continue
    }
    if (Test-GpuDevices $p) {
        $backend = $c; Write-Host "    $c : 可用" -ForegroundColor Green; break
    }
    Write-Host "    $c : 不可用，降级下一档" -ForegroundColor DarkGray
}
if (-not $backend) { $backend = "cpu" }

$exe = $exeTable[$backend]
if (-not (Test-Path $exe)) {
    foreach ($k in @("cuda13", "vulkan", "cpu")) {
        if (Test-Path $exeTable[$k]) { $exe = $exeTable[$k]; $backend = $k; break }
    }
}
if (-not (Test-Path $exe)) {
    Write-Host "  [错误] U盘 llama.cpp 目录里没有 llama-server.exe" -ForegroundColor Red
    Read-Host "  回车退出"; exit 1
}

$backendName = @{
    cuda13 = "NVIDIA CUDA 13.4  (显卡加速)"
    vulkan = "Vulkan  (AMD / Intel / 老NVIDIA 通用加速)"
    cpu    = "纯 CPU  (兼容模式，慢)"
}[$backend]
Write-Host "  已选后端 :  $backendName" -ForegroundColor Green

# ---------------- 5. 按显存 + 内存自动配上下文与卸载层数 ----------------
if ($Ngl -lt 0) {
    if ($backend -eq "cpu") { $Ngl = 0 } else { $Ngl = 99 }
}

$vramUnknown = $false
if ($Ctx -le 0) {
    # MiMo 9B: 8 层全注意力 / 4 个 KV 头 / head_dim 256
    #   KV 缓存约 32KB/token(f16)、16KB(q8_0)、8KB(q4_0)
    if ($backend -eq "cpu") {
        $Ctx = 8192
    } elseif ($nvVramGB -ge 15) { $Ctx = 65536
    } elseif ($nvVramGB -ge 11) { $Ctx = 32768
    } elseif ($nvVramGB -ge 8)  { $Ctx = 16384
    } elseif ($nvVramGB -ge 6)  { $Ctx = 8192
    } elseif ($nvVramGB -gt 0)  { $Ctx = 4096; $Ngl = 20
    } else {
        # 拿不到显存数字：nvidia-smi 不在 PATH，或这台机器走的是 Vulkan / AMD 卡。
        # 坑：这里别按显卡型号名字猜大小 —— 猜大了就是显存不足直接崩。
        #     给保守档，用户在 高级选项.bat 里确认能跑之后可以手动往上调。
        $Ctx = 8192
        $vramUnknown = $true
    }
}

# KV 量化：显存紧张就压一压（只压缓存精度，不动模型权重）
$kvType = "q8_0"
if ($backend -eq "cpu") { $kvType = "f16" }
elseif ($vramUnknown) { $kvType = "q4_0" }
elseif ($nvVramGB -gt 0 -and $nvVramGB -lt 9) { $kvType = "q4_0" }

$vramNote = $null
if ($vramUnknown -and $backend -ne "cpu") {
    $vramNote = "读不到本机显存大小，已按保守值起步（上下文 $Ctx、KV $kvType）。如果这台机器显存其实充足，用 高级选项.bat 的 [1] / [2] 手动提上去。"
}

# ---- 内存自动降级：内存不够时主动压低上下文，而不是等系统换页换死 ----
$ramNote = $null
if ($ramTiny) {
    if ($Ctx -gt 8192) { $Ctx = 8192 }
    $kvType = "q4_0"
    $ramNote = "内存只有 $ramGB GB，模型本身 $modelGB GB —— 已把上下文压到 $Ctx 并降低 KV 精度。会很慢，建议换内存更大的电脑。"
} elseif ($ramTight) {
    if ($Ctx -gt 16384) { $Ctx = 16384 }
    $ramNote = "内存 $ramGB GB 比较紧（模型 $modelGB GB），已把上下文压到 $Ctx 以减少换页。"
}

# 不用 mlock：内存紧张的机器上 mlock 会把可用内存锁死。
# 保持 mmap 默认值，让系统按需分页。

# ---------------- 6. 拼参数 ----------------
$llamaArgs = @(
    "-m", $model.FullName,
    "--alias", $alias,
    "--host", "127.0.0.1",
    "--port", "$Port",
    "--n-gpu-layers", "$Ngl",
    "--ctx-size", "$Ctx",
    "--threads", "$threads",
    "--jinja",
    "--reasoning-format", "deepseek",
    "--temp", "0.6",
    "--top-p", "0.95",
    "--top-k", "20",
    "--min-p", "0"
)
if ($backend -ne "cpu") {
    $llamaArgs += @("--flash-attn", "on", "--cache-type-k", $kvType, "--cache-type-v", $kvType)
}

Write-Host ""
Write-Host "  上下文   :  $Ctx tokens" -ForegroundColor DarkGray
Write-Host "  显存卸载 :  $Ngl 层  (KV 缓存 $kvType)" -ForegroundColor DarkGray
Write-Host "  CPU 线程 :  $threads" -ForegroundColor DarkGray
if ($vramNote) {
    Write-Host ""
    Write-Host "  [注意] $vramNote" -ForegroundColor Yellow
}
if ($ramNote) {
    Write-Host ""
    Write-Host "  [注意] $ramNote" -ForegroundColor Yellow
}

if ($Probe) {
    Head "探测完成（未启动引擎）"
    Write-Host "  后端 = $backend      模型 = $($model.Name)"
    Write-Host "  ctx  = $Ctx          ngl  = $Ngl         kv = $kvType"
    Write-Host "  内存 = $ramGB GB      显存 = $nvVramGB GB"
    exit 0
}

# ---------------- 7. 端口占用：分清"我们的"和"别人的" ----------------
function Test-PortBusy([int]$p) {
    try {
        $tc = New-Object Net.Sockets.TcpClient
        $tc.Connect("127.0.0.1", $p)
        $tc.Close()
        return $true
    } catch { return $false }
}

# 占用端口的那个服务，是不是我们这支 U 盘启动的？
function Test-OurServer([int]$p) {
    try {
        $r = Invoke-RestMethod -Uri "http://127.0.0.1:$p/props" -TimeoutSec 2 -ErrorAction Stop
        if ($r.PSObject.Properties.Name -contains "model_path") { return (Test-UnderRoot $r.model_path) }
        return $false
    } catch { return $false }
}

if (Test-PortBusy $Port) {
    Write-Host ""
    if (Test-OurServer $Port) {
        Write-Host "  [提示] 端口 $Port 上已经有本 U 盘的 AI 在运行。" -ForegroundColor Yellow
        Write-Host "         直接打开 http://127.0.0.1:$Port 就能用。" -ForegroundColor Yellow
        if (-not $NoBrowser) { Start-Process "http://127.0.0.1:$Port" }
        Read-Host "  回车退出"
        exit 0
    }

    Write-Host "  [提示] 端口 $Port 被别的程序占用了（不是本 U 盘的 AI）。" -ForegroundColor Yellow
    $newPort = 0
    for ($p = $Port + 1; $p -le $Port + 20; $p++) {
        if (-not (Test-PortBusy $p)) { $newPort = $p; break }
    }
    if ($newPort -eq 0) {
        Write-Host "         $Port ~ $($Port + 20) 全被占用，无法启动。请先释放端口。" -ForegroundColor Red
        Read-Host "  回车退出"; exit 1
    }
    $Port = $newPort
    for ($i = 0; $i -lt $llamaArgs.Count - 1; $i++) {
        if ($llamaArgs[$i] -eq "--port") { $llamaArgs[$i + 1] = "$Port" }
    }
    Write-Host "         已自动改用端口 $Port。" -ForegroundColor Green
}

# ---------------- 8. 启动 ----------------
$log = Join-Path $DirLog ("server-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".log")
$url = "http://127.0.0.1:$Port"

Head "正在启动 AI 引擎"
Write-Host "  加载 $modelGB GB 模型，约 10~60 秒，请勿关闭本窗口" -ForegroundColor Yellow
Write-Host "  日志: $log" -ForegroundColor DarkGray
Write-Host ""

$proc = Start-Process -FilePath $exe -ArgumentList $llamaArgs `
        -WorkingDirectory (Split-Path $exe -Parent) `
        -RedirectStandardOutput $log `
        -RedirectStandardError ($log + ".err") `
        -PassThru -NoNewWindow

Write-Host "  " -NoNewline
$ready = $false
for ($i = 0; $i -lt 300; $i++) {
    Start-Sleep -Seconds 1
    if ($proc.HasExited) { break }
    if ($i % 5 -eq 4) { Write-Host "." -NoNewline }
    try {
        $r = Invoke-WebRequest -Uri "$url/health" -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
        if ($r.StatusCode -eq 200) { $ready = $true; break }
    } catch { }
}
Write-Host ""

if ($proc.HasExited -and -not $ready) {
    Write-Host ""
    Write-Host "  [启动失败] 引擎退出了。错误信息：" -ForegroundColor Red
    Write-Host ""
    if (Test-Path ($log + ".err")) { Get-Content ($log + ".err") -Tail 25 }
    if (Test-Path $log)            { Get-Content $log -Tail 25 }
    Write-Host ""
    Write-Host "  常见原因与对策：" -ForegroundColor Yellow
    Write-Host "   1) 显存不够      -> 双击 高级选项.bat，选 [3] 省显存 / [4] Vulkan / [5] 纯CPU"
    Write-Host "   2) 没装显卡驱动  -> 选 [4] Vulkan 或 [5] 纯CPU"
    Write-Host "   3) 内存太小      -> 选 [5] 纯CPU（mmap 按需分页，比硬塞进显存稳）"
    Write-Host "   4) 杀毒软件拦截  -> 允许 llama-server.exe 运行"
    Write-Host "   5) exe 起不来    -> 见 docs/常见问题.md 的『缺少 DLL』一节"
    Read-Host "  回车退出"
    exit 1
}

if ($ready) {
    Write-Host ""
    Write-Host ("=" * 64) -ForegroundColor Green
    Write-Host "   AI 已就绪   ->   $url" -ForegroundColor Green
    Write-Host "   后端: $backendName" -ForegroundColor Green
    Write-Host ("=" * 64) -ForegroundColor Green
    if (-not $NoBrowser) { Start-Process $url }
} else {
    Write-Host "  等待超时。引擎可能还在加载，可直接访问 $url" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "  保持本窗口开启 = AI 持续运行。关闭窗口或 Ctrl+C 即停止。" -ForegroundColor DarkGray
try { Wait-Process -Id $proc.Id } catch { }
Write-Host "  引擎已停止。"
