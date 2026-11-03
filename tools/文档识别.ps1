# ====================================================================
#  portable-ai-usb  ·  文档识别.ps1
# ====================================================================
#  把文档图片转成 Markdown / JSON，用的是 Xiaomi-OCR-0（0.8B）。
#
#  为什么是独立脚本而不是塞进主启动器：
#    主模型 6.4 GB + KV 已经吃掉 8 GB 左右显存，8 GB 的卡上再加一个视觉模型
#    会直接爆。而 OCR 是「一次性工具」—— 丢几张图进去、等几秒、拿结果走人。
#    所以这里每次临时起一个引擎，处理完就关，不常驻、不抢主模型的位置。
#
#  为什么用 8090 而不是 8080：
#    8080 是主模型的位置，可能正在跑。这个脚本从不碰它，两个可以同时开着
#    （12 GB 以上的卡才建议这么干）。
# ====================================================================
[CmdletBinding()]
param(
    [string[]]$Image,          # 一张或多张图片
    [string]$Folder,           # 或者整个文件夹（不递归）
    [ValidateSet("doc", "text", "table", "formula", "kie")]
    [string]$Task = "doc",     # 任务类型，决定用哪条 prompt
    [string]$Schema = "",      # -Task kie 时的 JSON schema（可以给文件路径）
    [string]$OutDir = "",      # 输出目录，留空 = 和原图同目录
    [int]$Port = 8090,
    [int]$Ctx = 8192,
    [int]$GpuLayers = 99,
    [int]$TimeoutSec = 300,    # 单张图的生成超时
    [switch]$KeepServer,       # 处理完不关引擎（连续处理大批时省加载时间）
    [switch]$List              # 只列出找到了什么，不处理
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# ---------------- 1. 定位根目录与 OCR 模型 ----------------
# 脚本在 tools\ 里，根目录是上一层。所有路径都从 $PSScriptRoot 推导，
# 这样 U 盘插到哪个盘符、拷到哪个目录都不影响。
$Root = Split-Path -Parent $PSScriptRoot
$DirModels = Join-Path $Root "models"
$DirOcr = Join-Path $DirModels "ocr"

function Write-Head([string]$Text) {
    Write-Host ""
    Write-Host ("  " + $Text) -ForegroundColor Cyan
    Write-Host ("  " + ("-" * 56)) -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "  ============================================================" -ForegroundColor DarkCyan
Write-Host "    文档识别  ·  Xiaomi-OCR-0（图片 → Markdown / JSON）" -ForegroundColor White
Write-Host "  ============================================================" -ForegroundColor DarkCyan

if (-not (Test-Path $DirOcr)) {
    Write-Host ""
    Write-Host "  [错误] 找不到 OCR 模型目录：$DirOcr" -ForegroundColor Red
    Write-Host "         这个东西是单独下载的，不在 Git 仓库里。" -ForegroundColor Gray
    Write-Host "         装法：用 tools\准备U盘.ps1 重新组装一次（会自动补上），" -ForegroundColor Gray
    Write-Host "               或者手动把这两个文件放进 $DirOcr" -ForegroundColor Gray
    Write-Host "               · Xiaomi-OCR-0-Q5_K_M.gguf      （约 551 MB）" -ForegroundColor Gray
    Write-Host "               · mmproj-Xiaomi-OCR-0-F16.gguf   （约 198 MB）" -ForegroundColor Gray
    Write-Host "         来源：huggingface.co/prithivMLmods/Xiaomi-OCR-0-GGUF" -ForegroundColor Gray
    exit 1
}

# 模型本体：排除 mmproj，挑最大的那份（万一盘上放了多个量化）
# mmproj 有两种常见命名 —— llama.cpp 官方的 `mmproj-<模型>-<精度>.gguf`，和另一种
# `<模型>.mmproj-<精度>.gguf`（prithivMLmods 的仓库用的就是后一种）。只认前缀的话，
# 从那一类仓库下的投影文件永远找不到，引擎会「加载成功但看不见图」。
function Test-IsProj([string]$name) {
    return ($name -like "mmproj-*") -or ($name -like "*.mmproj-*")
}
$ocrModels = @(Get-ChildItem $DirOcr -Filter "*.gguf" -File -ErrorAction SilentlyContinue |
               Where-Object { -not (Test-IsProj $_.Name) } |
               Sort-Object Length -Descending)
# 视觉投影文件：引擎没有它就看不见图
$ocrProjs  = @(Get-ChildItem $DirOcr -Filter "*.gguf" -File -ErrorAction SilentlyContinue |
               Where-Object { Test-IsProj $_.Name } |
               Sort-Object Length -Descending)

if ($ocrModels.Count -eq 0) {
    Write-Host ""
    Write-Host "  [错误] $DirOcr 里没有 OCR 模型（*.gguf）" -ForegroundColor Red
    exit 1
}
if ($ocrProjs.Count -eq 0) {
    Write-Host ""
    Write-Host "  [错误] $DirOcr 里没有投影文件（mmproj-*.gguf）—— 引擎看不见图" -ForegroundColor Red
    Write-Host "         光有模型本体也能加载，但图片会被忽略，输出全是编的。" -ForegroundColor Yellow
    exit 1
}

$OcrModel = $ocrModels[0]
$OcrProj  = $ocrProjs[0]

# ---------------- 2. 找引擎 ----------------
# 和主启动器用同一套目录约定：llama.cpp\<backend>\llama-server.exe。
# 优先 CUDA，其次 Vulkan，最后 CPU —— 这个 0.8B 模型在 CPU 上也能跑，
# 只是慢几倍，所以兜底不要报错退出。
$exeCandidates = @(
    (Join-Path $Root "llama.cpp\cuda13\llama-server.exe"),
    (Join-Path $Root "llama.cpp\vulkan\llama-server.exe"),
    (Join-Path $Root "llama.cpp\cpu\llama-server.exe")
)
$Engine = $null
foreach ($c in $exeCandidates) { if (Test-Path $c) { $Engine = $c; break } }
if (-not $Engine) {
    Write-Host ""
    Write-Host "  [错误] U 盘上没有 llama.cpp 引擎 —— 先跑 tools\准备U盘.ps1" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "  OCR 模型 :  $($OcrModel.Name)   ($([math]::Round($OcrModel.Length / 1MB)) MB)" -ForegroundColor Green
Write-Host "  投影文件 :  $($OcrProj.Name)   ($([math]::Round($OcrProj.Length / 1MB)) MB)" -ForegroundColor Green
Write-Host "  引擎     :  $($Engine.Substring($Root.Length).TrimStart('\'))" -ForegroundColor DarkGray

# ---------------- 3. 收集要处理的图片 ----------------
$imgExts = @(".jpg", ".jpeg", ".png", ".webp", ".bmp", ".gif", ".tif", ".tiff")
$targets = @()

foreach ($p in @($Image)) {
    if (-not $p) { continue }
    $full = if ([IO.Path]::IsPathRooted($p)) { $p } else { Join-Path (Get-Location).Path $p }
    if (-not (Test-Path -LiteralPath $full)) { Write-Host "  [跳过] 找不到：$full" -ForegroundColor Yellow; continue }
    $it = Get-Item -LiteralPath $full
    # 传了文件夹要单独拦下。DirectoryInfo 没有 .DirectoryName / .Extension，
    # 后面拼输出路径时会拼出一个空目录，然后在 Join-Path 上直接抛异常、
    # 把已经起好的引擎丢在后台 —— 实测过，别再让它走到那儿。
    if ($it.PSIsContainer) {
        Write-Host "  [跳过] 这是文件夹，不是图片：$($it.FullName)" -ForegroundColor Yellow
        Write-Host "         要处理整个文件夹请用 -Folder；先用 -List 看一眼会挑出哪些。" -ForegroundColor Gray
        continue
    }
    if ($imgExts -notcontains $it.Extension.ToLower()) {
        Write-Host "  [跳过] 不是支持的图片格式（$($it.Extension)）：$($it.Name)" -ForegroundColor Yellow
        continue
    }
    $targets += @($it)
}
if ($Folder) {
    $fullDir = if ([IO.Path]::IsPathRooted($Folder)) { $Folder } else { Join-Path (Get-Location).Path $Folder }
    if (-not (Test-Path -LiteralPath $fullDir)) {
        Write-Host "  [错误] 找不到文件夹：$fullDir" -ForegroundColor Red
        exit 1
    }
    foreach ($f in @(Get-ChildItem -LiteralPath $fullDir -File -ErrorAction SilentlyContinue)) {
        if ($imgExts -contains $f.Extension.ToLower()) { $targets += $f }
    }
}

# 去重（同一张图既给了 -Image 又在 -Folder 里）
$targets = @($targets | Sort-Object FullName -Unique)

if ($targets.Count -eq 0) {
    Write-Host ""
    Write-Host "  没有要处理的图片。" -ForegroundColor Yellow
    Write-Host "  用法：" -ForegroundColor Gray
    Write-Host "    tools\文档识别.ps1 -Image 发票.jpg" -ForegroundColor Gray
    Write-Host "    tools\文档识别.ps1 -Folder D:\扫描件\ -Task doc" -ForegroundColor Gray
    Write-Host "    tools\文档识别.ps1 -List -Folder D:\扫描件\" -ForegroundColor Gray
    exit 1
}

Write-Host ""
Write-Host "  待处理   :  $($targets.Count) 个文件，任务 = $Task" -ForegroundColor White
foreach ($t in $targets) { Write-Host "    · $($t.Name)" -ForegroundColor DarkGray }

if ($List) { Write-Host ""; Write-Host "  （-List 只列清单，不启动引擎）" -ForegroundColor DarkGray; exit 0 }

# ---------------- 4. 任务对应的 prompt ----------------
# 这几条是模型作者给的官方模板，不是我们编的。换词会明显掉质量 ——
# 他们是按这些 prompt 做的对齐训练，换个说法输出格式就会飘。
$prompts = @{
    doc     = "Extract all information from the main body of the document image and represent it in markdown format, ignoring headers and footers. Tables should be expressed in OTSL format, formulas in the document should be represented using LATEX format, and the parsing should be organized according to the reading order."
    text    = "Extract the text in the image."
    table   = "Parse the table in the image into OTSL."
    formula = "Identify the formula in the image and represent it using LATEX format."
    kie     = "Extract key information in the image"
}
$prompt = $prompts[$Task]
if ($Task -eq "kie") {
    if (-not $Schema) {
        Write-Host ""
        Write-Host "  [错误] -Task kie 需要同时给 -Schema（JSON 结构说明）" -ForegroundColor Red
        Write-Host "         例：-Schema '{\"invoice_no\":\"string\",\"total\":\"string\"}'" -ForegroundColor Gray
        exit 1
    }
    $schemaText = $Schema
    if (Test-Path -LiteralPath $Schema) {
        try { $schemaText = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $Schema).Path, [Text.Encoding]::UTF8) }
        catch { Write-Host "  [错误] schema 文件读不出来：$Schema" -ForegroundColor Red; exit 1 }
    }
    $prompt = "$prompt`n`n$schemaText"
}

# ---------------- 5. 起临时引擎 ----------------
function Test-PortOpen([int]$p) {
    try {
        $tc = New-Object Net.Sockets.TcpClient
        $tc.Connect("127.0.0.1", $p)
        $tc.Close()
        return $true
    } catch { return $false }
}

if (Test-PortOpen $Port) {
    # 端口被占：可能是上一次 -KeepServer 留下的，也可能真是别的程序。
    # 不猜，直接说清楚让用户决定。
    Write-Host ""
    Write-Host "  [错误] 端口 $Port 已经被占用了。" -ForegroundColor Red
    Write-Host "         如果上一次用了 -KeepServer 没关，先跑：" -ForegroundColor Gray
    Write-Host "           tools\文档识别.ps1 -KeepServer  （不会走到这里）" -ForegroundColor DarkGray
    Write-Host "         或者换个端口：-Port 8091" -ForegroundColor Gray
    exit 1
}

$DirLog = Join-Path $Root "logs\ocr"
try { if (-not (Test-Path $DirLog)) { New-Item -ItemType Directory -Path $DirLog -Force | Out-Null } } catch { }
$logFile = Join-Path $DirLog ("ocr-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".log")

# 参数说明：
#   --no-webui  这个端口只给程序用，不需要网页界面
#   -c 8192     一页文档的图片 token + 输出，8K 足够；模型最长支持 256K 但没必要
#   --jinja     用模型自带的 chat template（OCR 模型必须开，否则图片 token 对不上）
$engineArgs = @(
    "-m", ("`"$($OcrModel.FullName)`""),
    "--mmproj", ("`"$($OcrProj.FullName)`""),
    "--host", "127.0.0.1",
    "--port", "$Port",
    "--ctx-size", "$Ctx",
    "--n-gpu-layers", "$GpuLayers",
    "--jinja",
    "--no-webui",
    # 官方参考实现用的是贪心解码（do_sample=False）。温度 0 + 关掉这几个采样开关，
    # 输出才和他们的基准一致；开着采样会在表格/公式上冒出随机的格式差异。
    "--temp", "0",
    "--top-k", "1"
)

Write-Host ""
Write-Host "  正在启动 OCR 引擎（0.8B，一般 3~6 秒）..." -ForegroundColor DarkYellow
$proc = Start-Process -FilePath $Engine -ArgumentList $engineArgs `
        -RedirectStandardOutput ($logFile + ".out") -RedirectStandardError $logFile `
        -PassThru -WindowStyle Hidden

$url = "http://127.0.0.1:$Port"
$ready = $false
for ($i = 0; $i -lt 120; $i++) {
    Start-Sleep -Milliseconds 500
    if ($proc.HasExited) { break }
    try {
        $r = Invoke-WebRequest -Uri "$url/health" -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
        if ($r.StatusCode -eq 200) { $ready = $true; break }
    } catch { }
}
if (-not $ready) {
    Write-Host ""
    Write-Host "  [错误] OCR 引擎没能起来。" -ForegroundColor Red
    if ($proc.HasExited) { Write-Host "         进程已退出。" -ForegroundColor Red }
    Write-Host "         日志最后 15 行：" -ForegroundColor Gray
    try { Get-Content $logFile -Tail 15 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "           $_" -ForegroundColor DarkGray } } catch { }
    if ($proc -and -not $proc.HasExited) { try { Stop-Process -Id $proc.Id -Force } catch { } }
    exit 1
}
Write-Host "  引擎就绪：$url" -ForegroundColor Green

# ---------------- 6. 逐张处理 ----------------
# 图片格式 → MIME。API 要的是 data URI，类型写错会 400。
function Get-Mime([string]$ext) {
    switch ($ext.ToLower()) {
        ".jpg"  { return "image/jpeg" }
        ".jpeg" { return "image/jpeg" }
        ".png"  { return "image/png" }
        ".webp" { return "image/webp" }
        ".bmp"  { return "image/bmp" }
        ".gif"  { return "image/gif" }
        ".tif"  { return "image/tiff" }
        ".tiff" { return "image/tiff" }
        default { return "image/jpeg" }
    }
}

$okCount = 0
$failCount = 0
$outFiles = @()

try {
foreach ($img in $targets) {
    $destDir = if ($OutDir) {
        if ([IO.Path]::IsPathRooted($OutDir)) { $OutDir } else { Join-Path (Get-Location).Path $OutDir }
    } else { $img.DirectoryName }
    try { if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null } } catch { }
    if (-not $destDir) { $destDir = (Get-Location).Path }

    # 输出名取「原文件名（不含扩展名）+ .md」。同名不同扩展名会撞车：
    # a.jpg 和 a.png 都会想要 a.md，后一个把前一个盖掉 —— 批量处理一整个
    # 文件夹时这等于静默丢数据。撞上了就加 -2 / -3，并说一句。
    $baseName = [IO.Path]::GetFileNameWithoutExtension($img.Name)
    $outPath  = Join-Path $destDir ($baseName + ".md")
    $dup = 2
    # 只防「同一批里撞车」，不管磁盘上已有的同名文件 —— 那是上一次的产出，
    # 重跑一遍覆盖掉才是预期行为。
    while ($outFiles -contains $outPath) {
        $outPath = Join-Path $destDir ("{0}-{1}.md" -f $baseName, $dup)
        $dup++
        if ($dup -gt 100) { break }
    }
    if ($dup -gt 2) {
        Write-Host "     [注意] 这一批里有同名文件，改存 $(Split-Path $outPath -Leaf)" -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "  → $($img.Name)  ($([math]::Round($img.Length / 1KB)) KB)" -ForegroundColor White
    $swItem = [Diagnostics.Stopwatch]::StartNew()
    try {
        $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($img.FullName))
        $mime = Get-Mime $img.Extension
        $body = @{
            messages = @(@{
                role = "user"
                content = @(
                    @{ type = "image_url"; image_url = @{ url = "data:$mime;base64,$b64" } },
                    @{ type = "text"; text = $prompt }
                )
            })
            # 官方参考实现是 max_new_tokens=4096。这里不设 temperature，
            # 因为引擎启动参数已经钉死成贪心解码了。
            max_tokens = 4096
        } | ConvertTo-Json -Depth 10 -Compress

        $resp = Invoke-RestMethod -Uri "$url/v1/chat/completions" -Method Post `
                -ContentType "application/json; charset=utf-8" `
                -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec $TimeoutSec
        $swItem.Stop()

        $text = [string]$resp.choices[0].message.content
        if (-not $text -or -not $text.Trim()) {
            Write-Host "     [失败] 模型返回了空内容" -ForegroundColor Red
            $failCount++
            continue
        }

        # 引擎有时会把整段输出包在 ```markdown 里。落盘时剥掉外层包裹，
        # 否则生成的 .md 里会多出一个 code fence，之后被别的工具再渲染一次就变成嵌套。
        $clean = $text.Trim()
        if ($clean -match '^```[a-zA-Z]*\r?\n([\s\S]*?)\r?\n```$') { $clean = $Matches[1].Trim() }

        [IO.File]::WriteAllText($outPath, $clean + "`r`n", (New-Object Text.UTF8Encoding($false)))
        $outFiles += $outPath
        $okCount++
        $gen = $resp.timings.predicted_n
        $pps = if ($resp.timings.predicted_per_second) { [math]::Round($resp.timings.predicted_per_second) } else { 0 }
        Write-Host ("     [OK] {0:N1} 秒 / {1} token / {2} tok/s  ->  {3}" -f $swItem.Elapsed.TotalSeconds, $gen, $pps, (Split-Path $outPath -Leaf)) -ForegroundColor Green
    } catch {
        $swItem.Stop()
        $msg = $_.Exception.Message
        Write-Host "     [失败] $msg" -ForegroundColor Red
        # 超时/上下文超限是最常见的两种，给具体一点的建议，别只丢一句英文异常
        if ($msg -match 'exceed|context') {
            Write-Host "           图太大或内容太长。试试先用图像工具把它压到 2000px 以内再跑。" -ForegroundColor Yellow
        } elseif ($msg -match 'timeout|timed out') {
            Write-Host "           超时了。加 -TimeoutSec 600 再试，或者换 CPU 以外的后端。" -ForegroundColor Yellow
        }
        $failCount++
    }
}
} finally {
    # 引擎必须在这里关。以前是循环跑完再关 —— 中间任何一处抛出未捕获的异常
    # （比如输出路径拼不出来），脚本当场结束，引擎就留在后台占着 8090 和显存，
    # 下次再跑会说「端口被占用」，用户只能自己去任务管理器杀。
    # 放 finally 里，正常结束、异常、Ctrl+C 之外的路径都能兜住。
    if (-not $KeepServer) {
        try { if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force } } catch { }
        Write-Host ""
        Write-Host "  OCR 引擎已关闭。" -ForegroundColor DarkGray
    } else {
        Write-Host ""
        Write-Host "  引擎保持运行：$url  （-KeepServer）" -ForegroundColor Yellow
        # 只说「记得自己关掉」不够 —— 大部分人不知道怎么关，下次再跑又会撞上
        # 「端口被占用」。把关闭命令直接写出来。
        Write-Host "  关掉它：在另一个 PowerShell 窗口执行" -ForegroundColor Gray
        Write-Host "    Get-Process llama-server -ErrorAction SilentlyContinue | Where-Object { `$_.Path -like '*\llama.cpp\*' } | Stop-Process -Force" -ForegroundColor DarkGray
    }
}

Write-Host ""
Write-Host "  ============================================================" -ForegroundColor DarkCyan
Write-Host ("    完成：成功 {0} 个 / 失败 {1} 个" -f $okCount, $failCount) -ForegroundColor $(if ($failCount -eq 0) { "Green" } else { "Yellow" })
foreach ($f in $outFiles) { Write-Host "    · $f" -ForegroundColor Gray }
Write-Host "  ============================================================" -ForegroundColor DarkCyan
Write-Host ""
if ($failCount -gt 0) { exit 1 }
