<#
================================================================
  portable-ai-usb  ·  准备U盘.ps1
================================================================
  作用：把「引擎 + 模型 + 启动器」组装到一支 U 盘（或任意目录）上，
        组装完之后那支 U 盘就不需要网络了。

  用法：
     powershell -ExecutionPolicy Bypass -File tools\准备U盘.ps1
     powershell -ExecutionPolicy Bypass -File tools\准备U盘.ps1 -Target E:
     powershell -ExecutionPolicy Bypass -File tools\准备U盘.ps1 -Source "你本机放 llama.cpp 的目录"

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

# 三个量化的真实大小与 SHA-256，取自 HuggingFace 的 LFS 元数据（文件自带的哈希），不是手抄的。
#
# 为什么必须校验哈希、不能只比大小：有的镜像会无视 Range 请求、把整个文件从头返回，
# 续传拼出来的文件**大小完全正确、内容却是坏的**，只比大小根本拦不住。
# 而一个下坏的模型比下不到更糟：它不会当场报错，会在启动或推理时抛奇怪的异常。
$ModelMeta = @{
    "Q4_K_M" = @{ Size = 5841049120; Sha = "4bca6f18c73f72270c7a20c2ea2bea581de8246e318714277120369d34048c81" }
    "Q5_K_M" = @{ Size = 6876124704; Sha = "04cf46f2b5584ef922697d6c063f94879434fb86c467f1a09e52daf0cddaf35f" }
    "Q8_0"   = @{ Size = 9545979424; Sha = "2fad0aa11bb9e7aa491ff12f768954f9dd0a6e7d4ce4a897ca73ec420f3b90ae" }
}
$ModelSize = $ModelMeta[$Quant].Size
$ModelSha  = $ModelMeta[$Quant].Sha

# 官方预编译包（含大小与 SHA-256，下完自动校验）
#
# 这些值取自 GitHub Release 的资产元数据。两份 cuda13 曾经只写了大小、没写哈希，
# 而且大小还是错的（152479372 / 423555290，实际 152497212 / 423535356）——
# 也就是说 U 盘上已有引擎时这个分支永远走不到，一旦在干净机器上跑就会
# 卡在「大小不对」上失败。现在两份都补上了真哈希，大小也不再是唯一防线。
#
# 想升级版本：改 $LlamaTag 后，用下面这条把新的名字/大小/哈希一次取全：
#   (irm "https://api.github.com/repos/ggml-org/llama.cpp/releases/tags/$LlamaTag" -Headers @{'User-Agent'='ps'}).assets |
#     ? name -match 'win.*x64' | select name,size,digest
$Engines = @{
    cpu    = @{ Zip = "llama-$LlamaTag-bin-win-cpu-x64.zip";    Size = 19165061; Sha = "4bb43ee0c7f4670d78087ba02eae7ae29b91e3d74eab3dbb337c6d0199bb7be0" }
    vulkan = @{ Zip = "llama-$LlamaTag-bin-win-vulkan-x64.zip"; Size = 33093376; Sha = "49366a9f824cdc9a937bfae9218cbb4adf0ff6bafc5b133ad7f03fb7940c1fb5" }
    cuda13 = @{
        Zips = @(
            @{ Zip = "llama-$LlamaTag-bin-win-cuda-13.4-x64.zip";    Size = 152497212; Sha = "a5c78087ebd2ad10b38639cc3bd240fb843123d6e37cdfee5f41178a1d2354b9" }
            @{ Zip = "cudart-llama-bin-win-cuda-13.4-x64.zip";       Size = 423535356; Sha = "738f8c251ac22b70c3ae6f83a10cf222725df0395246a2cf58f32bdb85fbe668" }
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

# 公共函数（Head / Step / OK / Info / Warn / Die / Ask-Yes / Get-File / Test-Sha256）
# 放在 _公共.ps1 里，和 换模型.ps1 共用一套下载逻辑。
. (Join-Path $PSScriptRoot "_公共.ps1")

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
$needGB += [math]::Round($ModelSize / 1GB, 1)
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
    # 先扫每块固定磁盘根目录下的 models\ ，再看用户目录
    $searchRoots = @()
    foreach ($d in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
                    Where-Object { $_.Root -match '^[A-Za-z]:\\$' })) {
        $searchRoots += (Join-Path $d.Root 'models')
    }
    $searchRoots += @("$env:USERPROFILE\Downloads", "$env:USERPROFILE\Desktop")

    foreach ($p in $searchRoots) {
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

            foreach ($z in $zipList) {
                $localZip = Join-Path $dlDir $z.Zip
                # 暂存目录里可能躺着上一次没收完的半截包。先验，验不过就删掉重下 ——
                # 「文件在就跳过」会让 Expand-Archive 在最后一步才失败，非常难查。
                if (Test-Path $localZip) {
                    if ((Get-Item $localZip).Length -eq $z.Size -and (Test-Sha256 $localZip $z.Sha)) { continue }
                    Info "暂存里的 $($z.Zip) 不完整，删掉重下"
                    Remove-Item $localZip -Force -ErrorAction SilentlyContinue
                }

                # 下之前先对一遍账：脚本里写死的大小会过期（上游重传一次资产就变了），
                # 而「大小不对」原本要等整个文件下完才报。HEAD 一秒就返回，能省掉白等。
                $remote = Get-RemoteSize "$LlamaBase/$($z.Zip)"
                if ($remote -gt 0 -and $remote -ne $z.Size) {
                    Write-Host ""
                    Warn "$($z.Zip) 的大小和脚本里记的不一样："
                    Warn "  脚本里记的：$($z.Size) 字节"
                    Warn "  GitHub 现在：$remote 字节"
                    Warn "多半是上游重新上传过这个文件。继续下也能下完，但随后的 SHA-256 校验大概率会失败。"
                    Warn "正确的做法：按本脚本顶部注释里的那行命令重新取一遍大小和 digest，更新 $Engines 之后再来。"
                    Write-Host ""
                    if (-not (Ask-Yes "仍然要尝试下载吗？" $false)) { Die "已停下 —— 先把脚本顶部的校验值更新掉。" }
                }

                # 尝试多个下载源（官方直连经常慢，镜像有时快）
                $mirrors = @("", "https://gh-proxy.com/", "https://ghproxy.net/")
                $got = $false
                foreach ($m in $mirrors) {
                    if ($got) { break }
                    Info "来源：$(if($m){$m}else{'github.com 直连'})"
                    if (Get-File -Url "$m$LlamaBase/$($z.Zip)" -Dest $localZip -Expected $z.Size) { $got = $true }
                }
                if (-not $got) { Die "下载失败：$($z.Zip)。可以手动下载后放到 $dlDir 再重跑本脚本。" }
                # 校验结果必须当场处理。丢掉它，坏包会在下面 Expand-Archive 那一行
                # 变成一句看不懂的解压错误 —— 离真正的原因隔了三层。
                if (-not (Test-Sha256 $localZip $z.Sha)) {
                    Remove-Item $localZip -Force -ErrorAction SilentlyContinue
                    Die "$($z.Zip) 校验失败，坏包已删。重跑本脚本会重新下载。"
                }
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
        # 用真实文件名做暂存名，避免不同量化之间串味；固定名会让换量化后接着下旧文件。
        $modelTmp = Join-Path $Stash "$ModelFile.part"
        Info "来源：hf-mirror.com（HuggingFace 国内镜像）"
        if (-not (Get-File -Url "$ModelRepo/$ModelFile" -Dest $modelTmp -Expected $ModelSize)) {
            Die "模型下载失败。可手动下载 $ModelFile 后放进 $dirModels 再重跑本脚本。"
        }
        # 大小对不算数（镜像无视 Range 时会拼出大小对、内容坏的文件），必须验哈希。
        if (-not (Test-Sha256 $modelTmp $ModelSha)) {
            Remove-Item $modelTmp -Force -ErrorAction SilentlyContinue
            Die "模型校验失败，坏文件已删。重跑本脚本会重新下载。"
        }
        Info "搬到 U 盘 ..."
        Move-Item $modelTmp $modelDst -Force
        OK "模型已就位"
    }
}

# ---------------- 5.5 模型校验清单 ----------------
# 上面下载时验过一次哈希，但那个值只活在这次运行里。用户几个月后觉得「模型是不是
# 坏了」时，手上没有任何基准。把实际哈希落到 models\校验.txt，tools\自检.ps1 拿它复查。
Step 5.5 "模型校验清单"
$manifest = Join-Path $dirModels "校验.txt"
$old = @{}
if (Test-Path $manifest) {
    foreach ($ln in @(Get-Content $manifest -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        # 格式：<64位十六进制>  <字节数>  <文件名>
        if ($ln -match '^\s*([0-9a-fA-F]{64})\s+(\d+)\s+(.+?)\s*$') {
            $old[$Matches[3]] = @{ Hash = $Matches[1].ToLower(); Size = [long]$Matches[2] }
        }
    }
}
$mOut = @("# 模型校验清单 —— 由 tools\准备U盘.ps1 生成，tools\自检.ps1 用它复查文件有没有坏。",
          "# 格式：<sha256>  <字节数>  <文件名>",
          "")
$mCount = 0
$ggufs = @(Get-ChildItem $dirModels -Filter "*.gguf" -File -ErrorAction SilentlyContinue | Sort-Object Name)
foreach ($g in $ggufs) {
    $k = $old[$g.Name]
    if ($k -and $k.Size -eq $g.Length) {
        # 大小没变就沿用旧哈希：6 GB 算一遍要几十秒，装卸 U 盘时没必要重算。
        $hv = $k.Hash
        Info "$($g.Name) 沿用已有记录"
    } else {
        Info "正在算 $($g.Name) 的哈希（$([math]::Round($g.Length / 1GB, 2)) GB，会占一会儿 CPU）..."
        try { $hv = (Get-FileHash $g.FullName -Algorithm SHA256 -ErrorAction Stop).Hash.ToLower() }
        catch { Warn "算不出来：$($_.Exception.Message)"; continue }
    }
    $mOut += ("{0}  {1}  {2}" -f $hv, $g.Length, $g.Name)
    $mCount++
}
[IO.File]::WriteAllText($manifest, ($mOut -join "`r`n") + "`r`n", (New-Object Text.UTF8Encoding($true)))
OK "校验.txt 已写入（$mCount 个模型）"

# ---------------- 6. 启动器 ----------------
Step 6 "启动器文件"
# 启动AI.sh 是给 macOS / Linux 用的。这支 U 盘插到 Mac 上也要能用，
# 所以即使在 Windows 上组装，这一份也必须一起带上。
foreach ($f in @("launcher.ps1", "启动AI.bat", "高级选项.bat", "启动AI.sh", "使用说明.txt")) {
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
