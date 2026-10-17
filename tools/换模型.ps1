# ====================================================================
#  portable-ai-usb  ·  换模型.ps1
# ====================================================================
#  作用：往 models\ 里下一个「已知能跑」的小模型，下完可以顺手设成默认。
#
#  用法：
#     powershell -ExecutionPolicy Bypass -File tools\换模型.ps1
#     powershell -ExecutionPolicy Bypass -File tools\换模型.ps1 -List
#     powershell -ExecutionPolicy Bypass -File tools\换模型.ps1 -Pick 5 -Yes
#     powershell -ExecutionPolicy Bypass -File tools\换模型.ps1 -Target E:
#
#  说明：
#     · 下面的每个模型都标了真实大小和 SHA-256，下完自动校验 —— 下坏了会告诉你，不会留个残文件
#     · 校验值取自 HuggingFace 的 LFS 元数据（文件本身自带的哈希），不是手抄的
#     · 下完不会自动删旧模型，磁盘不够时脚本会先提醒
#     · 装回去还是离线用：本脚本跑的时候才需要网
# ====================================================================
[CmdletBinding()]
param(
    [string]$Target,        # 目标：U 盘盘符（E:）或任意目录（D:\myusb）。缺省就用本仓库
    [switch]$List,          # 只列出清单和已装的，不下任何东西
    [int]$Pick = 0,         # 直接选第几号，配合 -Yes 可全自动
    [switch]$Yes            # 不问确认
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

. (Join-Path $PSScriptRoot "_公共.ps1")

# ==================== 模型清单（想加新的只改这里） ====================
# Size / Sha 都是从 HuggingFace 的 LFS 元数据取的实测值。
# ApproxRAM 是「能跑起来」的大致内存下限（含 KV 缓存与运行开销），用于提前劝退。
$Catalog = @(
    @{ N = "Qwen2.5-1.5B-Instruct"; Q = "Q4_K_M"; Size = 986048768;  Sha = "1adf0b11065d8ad2e8123ea110d1ec956dab4ab038eab665614adba04b6c3370"; Ram = 2.5; Note = "最小的一档，老机器 / 纯 CPU 也能跑" }
    @{ N = "Qwen2.5-3B-Instruct";   Q = "Q4_K_M"; Size = 1929903264; Sha = "9c9f56a391a3abbd5b89d0245bf6106081bcc3173119d4229235dd9d23253f94"; Ram = 4.0; Note = "小快稳，日常问答够用" }
    @{ N = "Llama-3.2-3B-Instruct"; Q = "Q4_K_M"; Size = 2019377696; Sha = "6c1a2b41161032677be168d354123594c0e6e67d2b9227c84f296ad037c728ff"; Ram = 4.0; Note = "英文写作比同尺寸顺" }
    @{ N = "google_gemma-3-4b-it";  Q = "Q4_K_M"; Size = 2489758112; Sha = "4996030242583a40aa151ff93f49ed787ac8c25e4120c3ae4588b2e2a7d1ae94"; Ram = 5.0; Note = "能看图（要另下投影文件）；多语言好" }
    @{ N = "Qwen3-4B";              Q = "Q4_K_M"; Size = 2497281312; Sha = "f6f851777709861056efcdad3af01da38b31223a3ba26e61a4f8bf3a2195813a"; Ram = 5.0; Note = "会先想再答，通用性最好的一档" }
    @{ N = "Qwen2.5-Coder-7B-Instruct"; Q = "Q4_K_M"; Size = 4683074336; Sha = "1664fccab734674a50763490a8c6931b70e3f2f8ec10031b54806d30e5f956b6"; Ram = 7.5; Note = "写代码；显存 6 GB 以上更舒服" }
    @{ N = "MiMo-V2.6-Distill-Qwen-9B"; Q = "Q5_K_M"; Size = 6876124704; Sha = "04cf46f2b5584ef922697d6c063f94879434fb86c467f1a09e52daf0cddaf35f"; Ram = 9.0; Note = "出厂自带的那个，中文最好" }
)

# 清单里 Sha 长度不足 64 位的，一律当作「没有可用哈希」处理，
# 这时只校验大小 —— 要诚实，不能让下载的人以为校验过了。
function Get-FullSha($m) {
    if ($m.Sha -and $m.Sha.Length -eq 64) { return $m.Sha.ToLower() }
    return ""
}

# Qwen3-4B 的仓库（unsloth 那份和官方那份内容一致，用 unsloth 的国内镜像更稳）
$Repo = @{
    "Qwen2.5-1.5B-Instruct"       = "bartowski/Qwen2.5-1.5B-Instruct-GGUF"
    "Qwen2.5-3B-Instruct"         = "bartowski/Qwen2.5-3B-Instruct-GGUF"
    "Llama-3.2-3B-Instruct"       = "bartowski/Llama-3.2-3B-Instruct-GGUF"
    "google_gemma-3-4b-it"        = "bartowski/google_gemma-3-4b-it-GGUF"
    "Qwen3-4B"                    = "unsloth/Qwen3-4B-GGUF"
    "Qwen2.5-Coder-7B-Instruct"   = "bartowski/Qwen2.5-Coder-7B-Instruct-GGUF"
    "MiMo-V2.6-Distill-Qwen-9B"   = "bartowski/MiMo-V2.6-Distill-Qwen-9B-GGUF"
}
$MirrorBase = "https://hf-mirror.com"

# 投影文件（给能看图的模型用），单独放一份清单
$Mmproj = @{
    For     = "google_gemma-3-4b-it"
    File    = "mmproj-google_gemma-3-4b-it-f16.gguf"
    Repo    = "bartowski/google_gemma-3-4b-it-GGUF"
    Size    = 851251104
    Sha     = "8c0fb064b019a6972856aaae2c7e4792858af3ca4561be2dbf649123ba6c40cb"
}

function Get-ModelFile($m) { return "$($m.N)-$($m.Q).gguf" }

# ---------------- 定目标目录 ----------------
$dirModels = if ($Target) {
    $t = $Target.TrimEnd('\', '/')
    if ($t -match '^[A-Za-z]:$') { Join-Path "$t\" "models" } else { Join-Path $t "models" }
} else {
    Join-Path $Root "models"
}

# ---------------- 屏幕上的表 ----------------
function Show-Catalog {
    Write-Host ""
    Write-Host "  可选的模型（都已验证过大小和 SHA-256）：" -ForegroundColor White
    Write-Host ""
    Write-Host ("   {0,-4} {1,-32} {2,-10} {3,-8} {4}" -f "编号", "模型", "量化", "文件大小", "说明") -ForegroundColor DarkGray
    Write-Host ("   " + ("-" * 88)) -ForegroundColor DarkGray
    for ($i = 0; $i -lt $Catalog.Count; $i++) {
        $m = $Catalog[$i]
        $installed = Test-Path (Join-Path $dirModels (Get-ModelFile $m))
        Write-Host ("   [{0,-2}] {1,-32} {2,-10} {3,-8} {4}{5}" -f `
            ($i + 1), $m.N, $m.Q, ("{0:N2} GB" -f ($m.Size / 1GB)), $m.Note,
            $(if ($installed) { "   [已装]" } else { "" })) -ForegroundColor $(if ($installed) { "DarkGray" } else { "Gray" })
    }
    Write-Host ""
    Write-Host "   另外，选 4 号（gemma-3-4b）时会问你要不要连投影文件一起下 ——" -ForegroundColor DarkGray
    Write-Host ("   加上它就能让模型看图（+{0:N2} GB）。" -f ($Mmproj.Size / 1GB)) -ForegroundColor DarkGray
}

function Show-Installed {
    $have = @(Get-ChildItem $dirModels -Filter "*.gguf" -File -ErrorAction SilentlyContinue)
    Write-Host ""
    Write-Host "  models\ 里现在有：" -ForegroundColor White
    if ($have.Count -eq 0) { Write-Host "   （空）" -ForegroundColor DarkGray; return }
    foreach ($f in ($have | Sort-Object Length -Descending)) {
        Write-Host ("   {0,-46} {1,8:N2} GB" -f $f.Name, ($f.Length / 1GB)) -ForegroundColor Gray
    }
    $cur = Join-Path $dirModels "当前模型.txt"
    if (Test-Path $cur) {
        # 空文件是可能的（编辑器里新建过、或手工清空过）。Get-Content -Raw 对空文件
        # 返回 $null，直接 .Trim() 会抛"不能对空值调用方法"，把整个脚本带走。
        $want = Get-Content $cur -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if ($want) { $want = $want.Trim() } else { $want = "（文件是空的）" }
        Write-Host "  当前模型.txt 指定的是：$want" -ForegroundColor Cyan
    } else {
        Write-Host "  （没有 当前模型.txt，启动时自动用最大的那个）" -ForegroundColor DarkGray
    }
}

# ---------------- 下单个文件 ----------------
function Get-Model($repo, $file, $size, $sha, $label) {
    $dest = Join-Path $dirModels $file
    if ((Test-Path $dest) -and (Get-Item $dest).Length -eq $size) {
        OK "$label 已存在且大小正确，跳过下载"
    } else {
        $url = "$MirrorBase/$repo/resolve/main/$file"
        Info "来源：$MirrorBase"
        if (-not (Get-File -Url $url -Dest $dest -Expected $size)) {
            Warn "下载失败：$file"
            Warn "可以手动下载后放到 $dirModels 里再重跑本脚本。"
            return $false
        }
    }
    if ($sha) {
        if (-not (Test-Sha256 $dest $sha)) {
            Warn "文件已损坏或不完整。删掉它再重跑本脚本：$dest"
            Remove-Item $dest -Force -ErrorAction SilentlyContinue
            return $false
        }
    } else {
        Info "（这个模型没有可用的完整 SHA-256，只校验了大小）"
    }
    return $true
}

function Set-Current($file) {
    $txt = Join-Path $dirModels "当前模型.txt"
    [System.IO.File]::WriteAllText($txt, $file, (New-Object System.Text.UTF8Encoding $false))
    OK "已设为默认模型：$file"
    Info "下次双击 启动AI.bat 就会用它。想换回来：运行 高级选项.bat 的 [10]。"
}

# ====================================================================
Head "portable-ai-usb  ·  换模型"
Write-Host "  目标位置 : $dirModels"

if (-not (Test-Path $dirModels)) {
    New-Item -ItemType Directory -Force -Path $dirModels | Out-Null
    Info "models\ 目录不存在，已新建"
}

if ($List) {
    Show-Installed
    Show-Catalog
    exit 0
}

Show-Installed
Show-Catalog

# ---------------- 选一个 ----------------
$idx = 0
if ($Pick -gt 0) {
    if ($Pick -gt $Catalog.Count) { Die "编号只有 1 到 $($Catalog.Count)，没有 $Pick" }
    $idx = $Pick
} else {
    if (-not (Test-CanAsk)) { Die "非交互模式要加 -Pick N 指定编号（1 到 $($Catalog.Count)）" }
    while ($true) {
        $a = Read-Host "   输入编号（1-$($Catalog.Count)），或直接回车取消"
        if ([string]::IsNullOrWhiteSpace($a)) { Write-Host "   已取消，什么都没下。" -ForegroundColor Gray; exit 0 }
        $n = 0
        if ([int]::TryParse($a.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $Catalog.Count) { $idx = $n; break }
        Write-Host "   1 到 $($Catalog.Count) 之间的数字，或者回车取消。" -ForegroundColor Yellow
    }
}

$pick = $Catalog[$idx - 1]
$pickFile = Get-ModelFile $pick

# ---------------- 磁盘空间够不够 ----------------
$need = $pick.Size
$wantMmproj = $false
if ($pick.N -eq $Mmproj.For) {
    if ($Yes) { $wantMmproj = $true }
    else { $wantMmproj = Ask-Yes "要不要连投影文件一起下？加上它模型就能看图（+$("{0:N2}" -f ($Mmproj.Size / 1GB)) GB）" $true }
    if ($wantMmproj) { $need += $Mmproj.Size }
}

# 剩余空间。不要用 (Get-Item $dir).PSDrive —— PowerShell 6+ 的 Get-Item 不再附带
# PSDrive / PSProvider 这两个注记属性，在 PowerShell 7 上拿到的是 $null，
# 于是空间检查**静默失效**：磁盘满了也不拦，下到一半才失败。
# 这里自己从路径取盘符，两种 PowerShell 上都成立。
$driveN = "?"
$freeGB = 0
try {
    $rootPath = [System.IO.Path]::GetPathRoot((Resolve-Path -LiteralPath $dirModels).Path)
    $letter = $rootPath.TrimEnd('\', '/').TrimEnd(':')
    if ($letter -match '^[A-Za-z]$') {
        $driveN = $letter
        $psd = Get-PSDrive -Name $letter -ErrorAction SilentlyContinue
        if ($psd -and $null -ne $psd.Free) { $freeGB = [math]::Round($psd.Free / 1GB, 2) }
    }
} catch { }
Write-Host ""
Info "需要下载 $("{0:N2}" -f ($need / 1GB)) GB，$driveN 盘剩余 $freeGB GB"
if ($freeGB -gt 0 -and $freeGB -lt ($need / 1GB + 1.0)) {
    Die "空间不够。可以先删掉不用的模型，或者换一支盘。"
}

# ---------------- 内存劝退（不是硬拦，只是提前说清楚） ----------------
$ramGB = 0
try {
    $ramGB = [math]::Round((Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory / 1GB, 1)
} catch { }
if ($ramGB -gt 0 -and $ramGB -lt $pick.Ram) {
    Write-Host ""
    Warn "这台机器内存 $ramGB GB，这个模型建议至少 $($pick.Ram) GB。"
    Warn "能下，但跑起来可能很慢或者加载失败 —— 想稳妥就选更小的那一档。"
    if (-not $Yes) { if (-not (Ask-Yes "还是要继续吗？" $false)) { Write-Host "   已取消。" -ForegroundColor Gray; exit 0 } }
}

# ---------------- 下 ----------------
Step 1 "下载 $pickFile"
$ok = Get-Model $Repo[$pick.N] $pickFile $pick.Size (Get-FullSha $pick) $pickFile

if ($ok -and $wantMmproj) {
    Step 2 "下载投影文件（视觉能力）"
    if (Get-Model $Mmproj.Repo $Mmproj.File $Mmproj.Size $Mmproj.Sha $Mmproj.File) {
        OK "以后启动时，启动器会自动认出它并打开视觉能力。"
    } else {
        # 模型本体已经装好了，只是看图能力没装成。这里不能沿用 $ok ——
        # 那会让下面报出"模型没下成功"，把一次成功的安装说成失败的。
        Warn "投影文件没下成功。模型本体是好的，只是暂时不能看图。"
        Warn "想要看图：重跑本脚本再选一次 4 号（模型已存在会自动跳过，只补投影文件）。"
    }
}

if (-not $ok) { Die "模型没下成功，磁盘上没留下完整文件。" }

# ---------------- 设成默认 ----------------
Step 3 "设为默认模型"
$setIt = if ($Yes) { $true } else { Ask-Yes "以后启动就用这个模型吗？" $true }
if ($setIt) { Set-Current $pickFile } else { Info "没改默认模型，启动时还是用原来那个。" }

Write-Host ""
Head "完成"
Show-Installed
Write-Host ""
# 换模型只改 models\当前模型.txt，启动器下次启动才读它。要是 AI 正开着，
# 你回到聊天界面会发现毫无变化 —— 会被当成「这功能坏了」，所以先说清楚。
$engines = @()
try {
    $modelRoot = Split-Path $dirModels -Parent
    $engines = @(Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue | Where-Object {
        $pth = $null
        try { $pth = $_.Path } catch { $pth = $null }   # 别的用户的进程读不到 Path
        $pth -and $pth.StartsWith($modelRoot, [StringComparison]::OrdinalIgnoreCase)
    })
} catch { }

if ($engines.Count -gt 0) {
    $pids = ($engines | ForEach-Object { $_.Id }) -join ', '
    Write-Host "  [注意] AI 现在正开着（PID $pids），换模型不会立刻生效。" -ForegroundColor Yellow
    Write-Host "         先关掉那个启动窗口，再双击 启动AI.bat，才会用上新模型。" -ForegroundColor Yellow
} else {
    Write-Host "  现在可以直接双击 启动AI.bat 试试。" -ForegroundColor Green
}
if ($ramGB -gt 0 -and $ramGB -lt $pick.Ram) {
    Write-Host "  （记得刚才那条内存提醒：这台机器跑它可能偏慢）" -ForegroundColor Yellow
}
Write-Host ""
Wait-Enter
