<#
================================================================
  portable-ai-usb  ·  准备U盘.ps1
================================================================
  作用：把「引擎 + 模型 + 启动器」组装到一支 U 盘（或任意目录）上，
        组装完之后那支 U 盘就不需要网络了。

  用法：
     powershell -ExecutionPolicy Bypass -File tools\准备U盘.ps1
     powershell -ExecutionPolicy Bypass -File tools\准备U盘.ps1 -Target E:
     powershell -ExecutionPolicy Bypass -File tools\准备U盘.ps1 -Source D:\llama.cpp

  说明：
     · 如果本机已经有一套 llama.cpp 和 GGUF 模型，用 -Source 直接拷，不走网络
     · 否则从 llama.cpp 官方 release 和 HuggingFace 镜像下载，支持断点续传
================================================================
#>
[CmdletBinding()]
param(
    [string]$Target,        # 目标：U 盘盘符（E:）或任意目录（D:\myusb）
    [string]$Source,        # 可选：本机已有的资源目录（里面找 llama.cpp / *.gguf）
    [string]$ModelPath,     # 可选：直接指定本机某个 .gguf 文件
    [ValidateSet("Q4_K_M", "Q5_K_M", "Q8_0")]
    [string]$Quant = "Q5_K_M",
    [switch]$SkipCuda,
    [switch]$SkipVulkan,
    [switch]$SkipCpu,
    [switch]$Yes            # 全部自动确认
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# ==================== 版本与来源（想升级只改这里） ====================
$LlamaTag   = "b11270"
$LlamaBase  = "https://github.com/ggml-org/llama.cpp/releases/download/$LlamaTag"
$ModelRepo  = "https://hf-mirror.com/bartowski/MiMo-V2.6-Distill-Qwen-9B-GGUF/resolve/main"
$ModelFile  = "MiMo-V2.6-Distill-Qwen-9B-$Quant.gguf"

# 官方预编译包（含大小与 SHA-256，下完自动校验）
$Engines = @{
    cpu    = @{ Zip = "llama-$LlamaTag-bin-win-cpu-x64.zip";    Size = 19165061; Sha = "4bb43ee0c7f4670d78087ba02eae7ae29b91e3d74eab3dbb337c6d0199bb7be0" }
    vulkan = @{ Zip = "llama-$LlamaTag-bin-win-vulkan-x64.zip"; Size = 33093376; Sha = "49366a9f824cdc9a937bfae9218cbb4adf0ff6bafc5b133ad7f03fb7940c1fb5" }
    cuda13 = @{
        Zips = @(
            @{ Zip = "llama-$LlamaTag-bin-win-cuda-13.4-x64.zip";    Size = 152479372; Sha = "" }
            @{ Zip = "cudart-llama-bin-win-cuda-13.4-x64.zip";       Size = 423555290; Sha = "" }
        )
    }
}

# 从 exe 同目录加载、缺了就跑不起来的运行库
$RuntimeDlls = @(
    "vcruntime140.dll", "vcruntime140_1.dll", "vcruntime140_threads.dll",
    "msvcp140.dll", "msvcp140_1.dll", "msvcp140_2.dll",
    "msvcp140_atomic_wait.dll", "msvcp140_codecvt_ids.dll",
    "concrt140.dll", "vcomp140.dll"
)

$Root   = Split-Path -Parent $PSScriptRoot          # 仓库根目录
$Stash  = Join-Path $env:TEMP "portable-ai-usb"     # 本机暂存（下载到这儿再拷过去）
if (-not (Test-Path $Stash)) { New-Item -ItemType Directory -Force -Path $Stash | Out-Null }

function Head($t) {
    Write-Host ""
    Write-Host ("=" * 68) -ForegroundColor DarkCyan
    Write-Host ("  " + $t) -ForegroundColor Cyan
    Write-Host ("=" * 68) -ForegroundColor DarkCyan
}
function Step($n, $t) { Write-Host ""; Write-Host "  [$n] $t" -ForegroundColor Yellow }
function OK($t)   { Write-Host "      ✓ $t" -ForegroundColor Green }
function Info($t) { Write-Host "      · $t" -ForegroundColor DarkGray }
function Warn($t) { Write-Host "      ! $t" -ForegroundColor Yellow }
function Die($t)  { Write-Host ""; Write-Host "  [错误] $t" -ForegroundColor Red; exit 1 }

function Ask-Yes($q, $defYes = $true) {
    if ($Yes) { return $true }
    $s = if ($defYes) { "[Y/n]" } else { "[y/N]" }
    $a = Read-Host "      $q $s"
    if ([string]::IsNullOrWhiteSpace($a)) { return $defYes }
    return ($a -match '^(?i)y')
}

# 断点续传下载。curl 的 -C - 会自动接上已有部分重新请求。
# 注意：某些镜像（如 gh-proxy.com）在收到 Range 请求时会挂住，所以必须带 --max-time，
#       每轮只跑 30 秒，靠外层循环累积进度。
function Get-File {
    param([string]$Url, [string]$Dest, [long]$Expected = 0)

    $destDir = Split-Path -Parent $Dest
    if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }

    if ($Expected -gt 0 -and (Test-Path $Dest) -and (Get-Item $Dest).Length -eq $Expected) {
        OK "已存在，跳过：$(Split-Path -Leaf $Dest)"
        return $true
    }

    $stall = 0; $round = 0
    while ($round -lt 600) {
        $round++
        $have = if (Test-Path $Dest) { (Get-Item $Dest).Length } else { 0 }
        if ($Expected -gt 0 -and $have -ge $Expected) { break }
        if ($Expected -gt 0) {
            Write-Host ("`r      下载中 ... {0,7:N1} / {1,7:N1} MB  (第 {2} 轮)" -f ($have / 1MB), ($Expected / 1MB), $round) -NoNewline
        } else {
            Write-Host ("`r      下载中 ... {0,7:N1} MB  (第 {1} 轮)" -f ($have / 1MB), $round) -NoNewline
        }

        & curl.exe -sS --ssl-no-revoke -L --max-time 30 -C - -o $Dest $Url 2>$null
        $after = if (Test-Path $Dest) { (Get-Item $Dest).Length } else { 0 }

        if ($after -gt $have) { $stall = 0 } else { $stall++; Start-Sleep -Seconds 2 }
        if ($stall -ge 8) { Write-Host ""; Warn "连续 $stall 轮没有进展，放弃这个来源"; return $false }
    }
    Write-Host ""

    $final = if (Test-Path $Dest) { (Get-Item $Dest).Length } else { 0 }
    if ($Expected -gt 0 -and $final -ne $Expected) {
        Warn "大小不对：期望 $Expected 字节，实际 $final 字节"
        return $false
    }
    OK "$(Split-Path -Leaf $Dest)  ($([math]::Round($final / 1MB, 1)) MB)"
    return $true
}

function Test-Sha256($Path, $Want) {
    if (-not $Want) { return $true }
    $got = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    if ($got -eq $Want.ToUpper()) { OK "SHA-256 校验通过"; return $true }
    Warn "SHA-256 不匹配！期望 $Want 实际 $got"
    return $false
}

# ====================================================================
Head "portable-ai-usb  ·  U盘组装"
Write-Host "  仓库位置 : $Root"

# ---------------- 1. 选目标 ----------------
Step 1 "选择目标位置"

if (-not $Target) {
    Write-Host ""
    Write-Host "  当前可用的磁盘：" -ForegroundColor DarkGray
    $vols = @(Get-Volume | Where-Object { $_.DriveLetter } | Sort-Object DriveLetter)
    foreach ($v in $vols) {
        $kind = if ($v.DriveType -eq 'Removable') { '【可移动】' } else { '          ' }
        Write-Host ("    {0}:  {1}  {2,-8} 剩余 {3,7:N1} GB   {4}" -f `
            $v.DriveLetter, $kind, $v.FileSystem, ($v.SizeRemaining / 1GB), $v.FileSystemLabel)
    }
    Write-Host ""
    $Target = Read-Host "  请输入 U 盘盘符或目标目录（如 E: 或 D:\myusb）"
}
if ([string]::IsNullOrWhiteSpace($Target)) { Die "没有指定目标" }

if ($Target -match '^[A-Za-z]:$') { $Target = "$Target\" }
if (-not (Test-Path $Target)) { Die "目标不存在：$Target" }
$Target = (Resolve-Path $Target).Path.TrimEnd('\')
Write-Host "  目标     : $Target"

# ---------------- 2. 检查文件系统 ----------------
Step 2 "检查文件系统"

$vol = Get-Volume -DriveLetter ([System.IO.Path]::GetPathRoot($Target).TrimEnd('\:')) -ErrorAction SilentlyContinue
$fsName = $null; $freeGB = 0
if ($vol) { $fsName = $vol.FileSystem; $freeGB = [math]::Round($vol.SizeRemaining / 1GB, 1) }

if ($fsName) { Write-Host "  文件系统 : $fsName     可用空间 : $freeGB GB" }

if ($fsName -eq "FAT32") {
    Write-Host ""
    Write-Host "  [需要处理] 目标是 FAT32 —— 单个文件最大 4 GB，装不下 6.4 GB 的模型。" -ForegroundColor Red
    Write-Host "             需要格式化成 exFAT 或 NTFS。这会清空该分区上的所有数据。" -ForegroundColor Red
    Write-Host ""
    $letter = [System.IO.Path]::GetPathRoot($Target).TrimEnd('\:')
    if (Ask-Yes "现在就把 $letter`: 格式化成 exFAT？（会清空）" $false) {
        $label = Read-Host "  卷标（直接回车用 USB-AI）"
        if ([string]::IsNullOrWhiteSpace($label)) { $label = "USB-AI" }
        Format-Volume -DriveLetter $letter -FileSystem exFAT -NewFileSystemLabel $label -Confirm:$false | Out-Null
        OK "已格式化为 exFAT，卷标 $label"
    } else {
        Die "请先手动格式化这个分区为 exFAT，然后重新运行本脚本"
    }
}

# 空间够不够
$needGB = 0
if (-not $SkipCpu)    { $needGB += 0.06 }
if (-not $SkipVulkan) { $needGB += 0.10 }
if (-not $SkipCuda)   { $needGB += 0.75 }
$needGB += @{ "Q4_K_M" = 5.5; "Q5_K_M" = 6.5; "Q8_0" = 9.0 }[$Quant]
$needGB += 0.2
if ($freeGB -gt 0 -and $freeGB -lt $needGB) { Die "可用空间不足：需要约 $needGB GB，只有 $freeGB GB" }
if ($freeGB -gt 0) { OK "空间够（约需 $needGB GB）" }

# ---------------- 3. 找资源 ----------------
Step 3 "准备引擎与模型"

$localLlama = $null
$localModel = $null

if ($Source) {
    if (Test-Path $Source) {
        $cand = Get-ChildItem $Source -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like "llama-b*" -or $_.Name -eq "llama.cpp" } | Select-Object -First 1
        if ($cand) { $localLlama = $cand.FullName; Info "本地引擎来源：$localLlama" }
        $gg = Get-ChildItem $Source -Recurse -Filter "*.gguf" -File -ErrorAction SilentlyContinue |
              Sort-Object Length -Descending | Select-Object -First 1
        if ($gg) { $localModel = $gg.FullName; Info "本地模型来源：$localModel" }
    } else { Warn "-Source 指向的路径不存在，改为联网下载" }
}
if ($ModelPath -and (Test-Path $ModelPath)) { $localModel = (Resolve-Path $ModelPath).Path }

# 自动找：本机常见位置
if (-not $localModel) {
    foreach ($p in @("D:\models", "$env:USERPROFILE\Downloads", "$env:USERPROFILE\Desktop")) {
        if (Test-Path $p) {
            $g = Get-ChildItem $p -Recurse -Filter "*.gguf" -File -ErrorAction SilentlyContinue |
                 Sort-Object Length -Descending | Select-Object -First 1
            if ($g -and $g.Length -gt 1GB) { $localModel = $g.FullName; Info "自动找到本机模型：$localModel"; break }
        }
    }
}

# ---------------- 4. 引擎 ----------------
$dirLlama = Join-Path $Target "llama.cpp"
$want = @()
if (-not $SkipCpu)    { $want += "cpu" }
if (-not $SkipVulkan) { $want += "vulkan" }
if (-not $SkipCuda)   { $want += "cuda13" }
if ($want.Count -eq 0) { Die "你把三种引擎全跳过了，没东西可装" }

$dlDir = Join-Path $Stash "downloads"
if (-not (Test-Path $dlDir)) { New-Item -ItemType Directory -Force -Path $dlDir | Out-Null }

foreach ($name in $want) {
    Step 4 "引擎：$name"
    $dst = Join-Path $dirLlama $name

    if (Test-Path (Join-Path $dst "llama-server.exe")) {
        OK "U盘上已有，跳过"
    } else {
        if ($localLlama) {
            # 从本机已有的引擎目录里挑同名的子目录 / 同族目录
            $srcDir = $null
            foreach ($probe in @($localLlama, (Join-Path (Split-Path -Parent $localLlama) $name))) {
                if (Test-Path (Join-Path $probe "llama-server.exe")) { $srcDir = $probe; break }
            }
            if (-not $srcDir) {
                # 单个目录（比如 llama-b11270-bin-win-cuda-13.4-x64）直接当同名引擎用
                if ($name -eq "cuda13" -and (Test-Path (Join-Path $localLlama "llama-server.exe"))) { $srcDir = $localLlama }
            }
            if ($srcDir) {
                Info "从本机复制：$srcDir"
                New-Item -ItemType Directory -Force -Path $dst | Out-Null
                Copy-Item (Join-Path $srcDir "*") $dst -Recurse -Force
                OK "已复制 $(@(Get-ChildItem $dst -File).Count) 个文件"
            } else {
                Warn "本机没有对应目录，改为下载"
            }
        }

        if (-not (Test-Path (Join-Path $dst "llama-server.exe"))) {
            New-Item -ItemType Directory -Force -Path $dst | Out-Null
            $spec = $Engines[$name]
            $zipList = if ($spec.Zips) { $spec.Zips } else { @($spec) }

            # 尝试多个下载源（官方直连经常慢，镜像有时快）
            $mirrors = @("", "https://gh-proxy.com/", "https://ghproxy.net/")
            foreach ($z in $zipList) {
                $got = $false
                $localZip = Join-Path $dlDir $z.Zip
                foreach ($m in $mirrors) {
                    if ($got) { break }
                    Info "来源：$(if($m){$m}else{'github.com 直连'})"
                    if (Get-File -Url "$m$LlamaBase/$($z.Zip)" -Dest $localZip -Expected $z.Size) { $got = $true }
                }
                if (-not $got) { Die "下载失败：$($z.Zip)。可以手动下载后放到 $dlDir 再重跑本脚本。" }
                Test-Sha256 $localZip $z.Sha | Out-Null
                Info "解压 $($z.Zip)"
                Expand-Archive -LiteralPath $localZip -DestinationPath $dst -Force
            }
            OK "引擎已就位"
        }
    }

    # ---- 补 VC++ 运行库（app-local，不碰宿主系统）----
    $missing = @()
    foreach ($d in $RuntimeDlls) {
        if (-not (Test-Path (Join-Path $dst $d))) {
            $src = Join-Path $env:WINDIR "System32\$d"
            if (Test-Path $src) { Copy-Item $src $dst -Force } else { $missing += $d }
        }
    }
    if ($missing.Count -gt 0) {
        Warn "本机 System32 里也缺这些 DLL：$($missing -join ', ')"
        Warn "装一下 Microsoft Visual C++ 2015-2022 Redistributable (x64)，再重跑本脚本。"
    } else {
        OK "VC++ 运行库已补齐（共 $((Get-ChildItem $dst -Filter '*.dll' -File).Count) 个 DLL）"
    }
}

# ---------------- 5. 模型 ----------------
Step 5 "模型：$ModelFile  约 $($Quant) 量化"
$dirModels = Join-Path $Target "models"
if (-not (Test-Path $dirModels)) { New-Item -ItemType Directory -Force -Path $dirModels | Out-Null }
$modelDst = Join-Path $dirModels $ModelFile

if (Test-Path $modelDst) {
    OK "U盘上已有，跳过（$([math]::Round((Get-Item $modelDst).Length / 1GB, 2)) GB）"
} else {
    $ok = $false
    if ($localModel) {
        Info "从本机复制：$localModel"
        $sz = (Get-Item $localModel).Length
        $sw = [Diagnostics.Stopwatch]::StartNew()
        # 大文件用 /J 无缓冲拷贝，比 Copy-Item 快很多
        $r = & robocopy (Split-Path -Parent $localModel) $dirModels (Split-Path -Leaf $localModel) /J /NJH /NJS /NDL /NP /R:2 /W:2
        if ((Test-Path $modelDst) -and (Get-Item $modelDst).Length -eq $sz) {
            $sw.Stop()
            OK "已复制 $([math]::Round($sz / 1GB, 2)) GB，用时 $([math]::Round($sw.Elapsed.TotalSeconds)) 秒"
            $ok = $true
        } else { Warn "复制结果大小不对，改为下载" }
    }
    if (-not $ok) {
        $localZip = Join-Path $Stash "model-$Quant.gguf.part"
        Info "来源：hf-mirror.com（HuggingFace 国内镜像）"
        if (-not (Get-File -Url "$ModelRepo/$ModelFile" -Dest $localZip)) {
            Die "模型下载失败。可手动下载 $ModelFile 后放进 $dirModels 再重跑本脚本。"
        }
        Info "搬到 U 盘 ..."
        Move-Item $localZip $modelDst -Force
        OK "模型已就位"
    }
}

# ---------------- 6. 启动器 ----------------
Step 6 "启动器文件"
foreach ($f in @("launcher.ps1", "启动AI.bat", "高级选项.bat", "使用说明.txt")) {
    $s = Join-Path $Root $f
    if (Test-Path $s) { Copy-Item $s $Target -Force; OK $f }
    else { Warn "仓库里找不到 $f" }
}
# 文档与工具
foreach ($d in @("docs", "tools")) {
    $s = Join-Path $Root $d
    if (Test-Path $s) {
        $t = Join-Path $Target $d
        if (-not (Test-Path $t)) { New-Item -ItemType Directory -Force -Path $t | Out-Null }
        Copy-Item (Join-Path $s "*") $t -Recurse -Force -ErrorAction SilentlyContinue
    }
}
OK "docs\ 与 tools\ 已一并复制"

# ---------------- 7. 校验 ----------------
Step 7 "组装结果"

$exeCount = 0
foreach ($name in $want) {
    $p = Join-Path $dirLlama "$name\llama-server.exe"
    if (Test-Path $p) { $exeCount++; OK "$name  llama-server.exe  OK" } else { Warn "$name  缺失 llama-server.exe" }
}
if (Test-Path $modelDst) { OK "模型 $([math]::Round((Get-Item $modelDst).Length / 1GB, 2)) GB" } else { Warn "模型缺失" }

$usedGB = [math]::Round((Get-ChildItem $Target -Recurse -File -ErrorAction SilentlyContinue |
           Measure-Object -Property Length -Sum).Sum / 1GB, 2)

Write-Host ""
Write-Host ("=" * 68) -ForegroundColor Green
Write-Host "   组装完成   ->   $Target" -ForegroundColor Green
Write-Host "   引擎 $exeCount 套 / 占用 $usedGB GB" -ForegroundColor Green
Write-Host ("=" * 68) -ForegroundColor Green
Write-Host ""
Write-Host "   拔下 U 盘，插到任意 Windows 电脑，双击「启动AI.bat」即可。" -ForegroundColor Cyan
Write-Host "   从这一刻起，这支 U 盘不再需要网络。" -ForegroundColor Cyan
Write-Host ""
