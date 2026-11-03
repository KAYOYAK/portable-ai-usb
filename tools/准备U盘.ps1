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

# 多模态投影文件（视觉能力）。主模型是 image-text-to-text 的，缺了这份就只能纯文本 ——
# 启动器会显示「视觉能力 : 关」，问它图里有什么它只能编。
# 同一个仓库里 f16 / bf16 两份都有，这里用 f16：比 bf16 小 3 MB，而且本项目 gemma
# 那份也是 f16，行为一致。
$MmprojFile = "mmproj-MiMo-V2.6-Distill-Qwen-9B-f16.gguf"
$MmprojSize = 918166048
$MmprojSha  = "ff348f3180a63188aa7285db85f550fe38acb61dd013c599eb8bad08d2cc2576"

# ---------------- 文档识别模型（Xiaomi-OCR-0，0.8B） ----------------
# 和主模型是两个东西：主模型 6.4 GB 常驻显存负责聊天，这个是「图片转 Markdown」
# 的一次性工具，跑完就关。放在 models\ocr\ 子目录 —— 启动器枚举模型时不递归，
# 所以它永远不会被误选成聊天模型。
#
# 源仓库的文件名是后缀式（Xiaomi-OCR-0.mmproj-bf16.gguf），落地时改成 llama.cpp
# 官方的前缀式（mmproj-Xiaomi-OCR-0-F16.gguf），和本项目其他投影文件保持一致。
$OcrRepo      = "https://hf-mirror.com/prithivMLmods/Xiaomi-OCR-0-GGUF/resolve/main"
$OcrModelFile = "Xiaomi-OCR-0.Q5_K_M.gguf"
$OcrModelSize = 577999104
$OcrModelSha  = "941843ae6fd31dc62eff7619eede813e6b3df664a6eb6a25bb8406fc65641e94"
$OcrProjSrc   = "Xiaomi-OCR-0.mmproj-bf16.gguf"
$OcrProjFile  = "mmproj-Xiaomi-OCR-0-F16.gguf"
$OcrProjSize  = 207346624
$OcrProjSha   = "634d6bc95781ebf4a3f06570a59859fa5082d488db540fd474bc6b4061aec90e"

# ---------------- AI 编程助手（MiMo Code） ----------------
# 它发布的是 Bun 编译的独立可执行文件，不是 npm 包里的 JS —— 所以这支盘
# 不需要 Node 运行时，解压出一个可执行文件就能跑。
#
# 六个平台全放，和 llama.cpp 放三套引擎是一个道理：插到哪台机器上都能跑，
# 不让用户卡在「你这台没有对应版本」。合计 zip 约 246 MB、解开约 780 MB。
# 解开的文件放 agent\<平台>\ 里，agent.ps1 按当前平台找自己那份。
#
# 唯一一处不如本项目其他组件的地方：FDS 不发布 .sha256，所以这里没法像引擎和
# 模型那样校验哈希，只能验大小 + 解压后跑一次 --version 确认真的能执行。
# （macOS/Linux 的那几份没法在 Windows 上执行验证，只能验大小和压缩包结构。）
$MimoVersion = "0.1.16"
$MimoBase    = "https://mimocode.cnbj1.mi-fds.com/mimocode/mimocode"
$MimoPlatforms = @(
    @{ Id = "windows-x64";   Zip = "zip";    Size = 48123337 }   # Windows 主力
    @{ Id = "windows-arm64"; Zip = "zip";    Size = 46376468 }   # Windows on ARM
    @{ Id = "darwin-arm64";  Zip = "zip";    Size = 33821856 }   # Apple Silicon
    @{ Id = "darwin-x64";    Zip = "zip";    Size = 36144524 }   # Intel Mac
    @{ Id = "linux-x64";     Zip = "tar.gz"; Size = 46610714 }   # Linux 主力
    @{ Id = "linux-arm64";   Zip = "tar.gz"; Size = 46276173 }   # ARM Linux
)
# 每个平台包解开后的可执行文件名。Windows 带 .exe，别的平台是裸文件。
function Get-MimoExeName([string]$platformId) {
    if ($platformId -like "windows-*") { return "mimo.exe" }
    return "mimo"
}

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

# ---------------- 5.5 多模态投影文件（视觉能力） ----------------
# 以前这一步完全没有：主模型是 image-text-to-text 的，但组装脚本只下模型本体，
# 于是「重跑准备U盘」装出来的盘都是纯文本的，用户得自己去 HuggingFace 翻一个
# mmproj-*.gguf 放进 models\ 才能看图。这属于重装必丢的东西，所以补进来。
Step 5.5 "多模态投影文件"
$haveProj = @(Get-ChildItem $dirModels -Filter "mmproj-*.gguf" -File -ErrorAction SilentlyContinue)
if ($haveProj.Count -gt 0) {
    OK "已有投影文件，跳过（$($haveProj[0].Name)）"
} else {
    Info "主模型是多模态的，补一个投影文件（$([math]::Round($MmprojSize / 1MB, 0)) MB），下完就能看图"
    Info "来源：hf-mirror.com（HuggingFace 国内镜像）"
    $projTmp = Join-Path $Stash "$MmprojFile.part"
    if (-not (Get-File -Url "$ModelRepo/$MmprojFile" -Dest $projTmp -Expected $MmprojSize)) {
        # 下不到不算致命：没有它照样能聊天，只是看不了图。别因此把整次组装判失败。
        Warn "投影文件没下成功。不影响聊天，只是看不了图；可以重跑本脚本再试。"
    } elseif (-not (Test-Sha256 $projTmp $MmprojSha)) {
        Remove-Item $projTmp -Force -ErrorAction SilentlyContinue
        Warn "投影文件校验失败，坏文件已删。不影响聊天，只是看不了图。"
    } else {
        Move-Item $projTmp (Join-Path $dirModels $MmprojFile) -Force
        OK "视觉能力已就绪（启动时横幅会显示「视觉能力 : 开」）"
    }
}

# ---------------- 5.6 模型校验清单 ----------------
# 上面下载时验过一次哈希，但那个值只活在这次运行里。用户几个月后觉得「模型是不是
# 坏了」时，手上没有任何基准。把实际哈希落到 models\校验.txt，tools\自检.ps1 拿它复查。
Step 5.6 "模型校验清单"
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
$mOut = @("# 模型校验清单 —— 由 tools\准备U盘.ps1 / tools\换模型.ps1 生成，tools\自检.ps1 用它复查文件有没有坏。",
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

# ---------------- 5.7 文档识别模型 ----------------
# 可选组件：不下也能正常聊天，只是菜单 [23]「文档识别」用不了。
# 所以失败只 Warn，不 Die —— 不能因为一个可选工具没下到就判整次组装失败。
Step 5.7 "文档识别模型（可选）"
$dirOcr = Join-Path $dirModels "ocr"
if (-not (Test-Path $dirOcr)) { New-Item -ItemType Directory -Path $dirOcr -Force | Out-Null }

$ocrModelDst = Join-Path $dirOcr $OcrModelFile
$ocrProjDst  = Join-Path $dirOcr $OcrProjFile
$ocrSkip = 0
if (Test-Path $ocrModelDst) {
    OK "OCR 模型已在，跳过（$([math]::Round((Get-Item $ocrModelDst).Length / 1MB)) MB）"
    $ocrSkip++
} else {
    Info "下载 Xiaomi-OCR-0（0.8B，图片转 Markdown）—— $([math]::Round($OcrModelSize / 1MB)) MB"
    $t = Join-Path $Stash "$OcrModelFile.part"
    if (-not (Get-File -Url "$OcrRepo/$OcrModelFile" -Dest $t -Expected $OcrModelSize)) {
        Warn "OCR 模型没下成功。不影响聊天，只是菜单 [23] 用不了。"
    } elseif (-not (Test-Sha256 $t $OcrModelSha)) {
        Remove-Item $t -Force -ErrorAction SilentlyContinue
        Warn "OCR 模型校验失败，坏文件已删。不影响聊天。"
    } else {
        Move-Item $t $ocrModelDst -Force
        OK "OCR 模型就位"
    }
}
if (Test-Path $ocrProjDst) {
    OK "OCR 投影文件已在，跳过（$([math]::Round((Get-Item $ocrProjDst).Length / 1MB)) MB）"
} else {
    Info "下载 OCR 投影文件 —— $([math]::Round($OcrProjSize / 1MB)) MB"
    $t = Join-Path $Stash "$OcrProjSrc.part"
    if (-not (Get-File -Url "$OcrRepo/$OcrProjSrc" -Dest $t -Expected $OcrProjSize)) {
        Warn "OCR 投影文件没下成功。菜单 [23] 用不了。"
    } elseif (-not (Test-Sha256 $t $OcrProjSha)) {
        Remove-Item $t -Force -ErrorAction SilentlyContinue
        Warn "OCR 投影文件校验失败，坏文件已删。"
    } else {
        Move-Item $t $ocrProjDst -Force
        OK "OCR 投影文件就位（菜单 [23] 可用）"
    }
}

# OCR 那两份也要进 models\校验.txt。顺序上 5.6 已经写完了清单（那时 OCR 还没下），
# 而下载时验过的哈希不落盘就等于没验 —— 以后没人能复查这两个文件坏没坏。
# 所以这里把已经就位的补写进去，已有的条目保留。
$manifestOcr = Join-Path $dirModels "校验.txt"
if (Test-Path $manifestOcr) {
    try {
        $exist = @{}
        foreach ($ln in @(Get-Content $manifestOcr -Encoding UTF8 -ErrorAction SilentlyContinue)) {
            if ($ln -match '^\s*[0-9a-fA-F]{64}\s+\d+\s+(.+?)\s*$') { $exist[$Matches[1]] = $true }
        }
        $add = @()
        foreach ($pair in @(@{ P = $ocrModelDst; S = $OcrModelSha }, @{ P = $ocrProjDst; S = $OcrProjSha })) {
            if (-not (Test-Path $pair.P)) { continue }
            $nm = Split-Path $pair.P -Leaf
            if ($exist.ContainsKey($nm)) { continue }
            $add += ("{0}  {1}  {2}" -f $pair.S.ToLower(), (Get-Item $pair.P).Length, $nm)
        }
        if ($add.Count -gt 0) {
            $cur = [IO.File]::ReadAllText($manifestOcr)
            if (-not $cur.EndsWith("`n")) { $cur += "`r`n" }
            [IO.File]::WriteAllText($manifestOcr, $cur + ($add -join "`r`n") + "`r`n", (New-Object Text.UTF8Encoding($true)))
            OK "校验清单补入 $($add.Count) 条 OCR 记录"
        }
    } catch {
        Warn "OCR 记录没写进校验清单（$($_.Exception.Message)）—— 不影响使用。"
    }
}

# ---------------- 5.8 AI 编程助手（可选） ----------------
# MiMo Code 的发布物是 Bun 编的独立可执行文件，不需要 Node。所以这里只是
# 「下压缩包、解出二进制」，不做 npm install，也不碰宿主机环境。
#
# 六个平台全下：插到哪台机器上都能跑。跑不了的平台那份也就 30~46 MB 压缩，
# 解开 100 多 MB —— 相比 105 GB 的余量，不值得为省这点让用户卡住。
Step 5.8 "AI 编程助手（可选）"
$dirAgent = Join-Path $Target "agent"
if (-not (Test-Path $dirAgent)) { New-Item -ItemType Directory -Path $dirAgent -Force | Out-Null }
$mimoVerFile = Join-Path $dirAgent "版本.txt"
# 只判「文件在不在」的话，升级版本时永远走不到下载分支 —— 盘上那份会一直停在
# 出厂版本，而我们自己都不知道它旧了。所以先比对版本号，再逐平台补缺。
$mimoHave = ""
if (Test-Path $mimoVerFile) {
    try { $mimoHave = ([IO.File]::ReadAllText($mimoVerFile)).Trim() } catch { }
}
$mimoUpgrade = ($mimoHave -ne $MimoVersion)
if ($mimoUpgrade) {
    if ($mimoHave) { Info "盘上是 v$mimoHave，目标 v$MimoVersion —— 逐平台更新" }
    else { Info "准备 MiMo Code v$MimoVersion（6 个平台，合计约 246 MB，不需要 Node）" }
}

$mimoOkCount = 0
$mimoFail = @()
foreach ($mp in $MimoPlatforms) {
    $pid2 = $mp.Id
    $exeName = Get-MimoExeName $pid2
    $pdir = Join-Path $dirAgent $pid2
    $dst = Join-Path $pdir $exeName

    # 版本一致且文件在 → 跳过这个平台
    if ((-not $mimoUpgrade) -and (Test-Path $dst)) {
        $mimoOkCount++
        continue
    }
    if (-not (Test-Path $pdir)) { New-Item -ItemType Directory -Path $pdir -Force | Out-Null }

    $archive = "mimocode-$pid2.$($mp.Zip)"
    $url = "$MimoBase/releases/v$MimoVersion/$archive"
    $tmpArc = Join-Path $Stash "$archive.$MimoVersion"
    if (-not (Get-File -Url $url -Dest $tmpArc -Expected $mp.Size)) {
        $mimoFail += $pid2
        continue
    }
    $tmpEx = Join-Path $Stash "mimocode-unzip-$pid2"
    try {
        if (Test-Path $tmpEx) { Remove-Item $tmpEx -Recurse -Force }
        New-Item -ItemType Directory -Path $tmpEx -Force | Out-Null
        if ($mp.Zip -eq "tar.gz") { & tar.exe -xzf $tmpArc -C $tmpEx 2>&1 | Out-Null }
        else { & tar.exe -xf $tmpArc -C $tmpEx 2>&1 | Out-Null }
        $found = @(Get-ChildItem $tmpEx -Filter $exeName -File -Recurse -ErrorAction SilentlyContinue)
        if ($found.Count -eq 0) {
            $mimoFail += $pid2
            continue
        }
        Copy-Item $found[0].FullName $dst -Force
        # 只有当前平台的能真跑一下验证。别的平台的包结构对不对，只能看它解出来
        # 有没有那个二进制 —— Windows 上不可能执行 Linux 的 ELF。
        $canRun = ($pid2 -eq "windows-x64") -or ($pid2 -eq "windows-arm64")
        if ($canRun -and $pid2 -eq "windows-x64") {
            $ver = (& $dst --version 2>&1 | Out-String).Trim()
            if ($LASTEXITCODE -ne 0 -or -not $ver) {
                Remove-Item $dst -Force -ErrorAction SilentlyContinue
                $mimoFail += $pid2
                continue
            }
        }
        $mimoOkCount++
    } catch {
        $mimoFail += $pid2
    } finally {
        Remove-Item $tmpEx -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $tmpArc -Force -ErrorAction SilentlyContinue
    }
}

if ($mimoFail.Count -eq 0) {
    try { [IO.File]::WriteAllText($mimoVerFile, "$MimoVersion`r`n", (New-Object Text.UTF8Encoding($false))) } catch { }
    OK "AI 编程助手就位：$mimoOkCount 个平台 / v$MimoVersion"
} else {
    Warn "AI 编程助手部分平台没下成功：$($mimoFail -join ', ')"
    Warn "不影响聊天和文档识别；那几台上 AI编程 会用不了。重跑本脚本可以补。"
    # 版本文件只在全部成功时写 —— 否则下次会以为已经是最新、不再补缺。
    if ($mimoOkCount -gt 0 -and -not (Test-Path $mimoVerFile)) {
        try { [IO.File]::WriteAllText($mimoVerFile, "partial-$(Get-Date -Format 'yyyyMMdd')`r`n", (New-Object Text.UTF8Encoding($false))) } catch { }
    }
}

# ---------------- 6. 启动器 ----------------
Step 6 "启动器文件"
# 启动AI.sh 是给 macOS / Linux 用的。这支 U 盘插到 Mac 上也要能用，
# 所以即使在 Windows 上组装，这一份也必须一起带上。
foreach ($f in @("launcher.ps1", "启动AI.bat", "高级选项.bat", "AI编程.bat", "启动AI.sh", "使用说明.txt")) {
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

# 两个可选组件也要在结果里露一面 —— 否则用户不知道菜单 [23] 和 AI编程.bat
# 到底能不能用，得自己去翻目录才知道。
$ocrBodyChk = @(Get-ChildItem $dirOcr -Filter "*.gguf" -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notlike "mmproj-*" -and $_.Name -notlike "*.mmproj-*" })
$ocrProjChk = @(Get-ChildItem $dirOcr -Filter "*.gguf" -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like "mmproj-*" -or $_.Name -like "*.mmproj-*" })
if ($ocrBodyChk.Count -gt 0 -and $ocrProjChk.Count -gt 0) {
    OK "文档识别 就绪（菜单 [23]）"
} else {
    Info "文档识别 未安装 —— 不影响聊天，只是菜单 [23] 用不了"
}
# AI 编程：数一下真的落盘了几个平台，而不是只看某一个文件在不在。
$mimoHaveCount = @($MimoPlatforms | Where-Object {
    $d = Join-Path $dirAgent $_.Id
    Test-Path (Join-Path $d (Get-MimoExeName $_.Id))
}).Count
if ($mimoHaveCount -gt 0) {
    OK "AI 编程 就绪（$mimoHaveCount / $($MimoPlatforms.Count) 个平台，AI编程.bat）"
    if ($mimoHaveCount -lt $MimoPlatforms.Count) {
        Info "  缺平台的机器上这个功能用不了；重跑本脚本会补。"
    }
} else {
    Info "AI 编程 未安装 —— 不影响聊天，只是 AI编程.bat 用不了"
}

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
