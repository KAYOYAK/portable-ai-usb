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
    [switch]$Stop,                 # 只停掉"本 U 盘"启动的引擎
    [switch]$Bench,                # 只测这支 U 盘的读取速度，不启动
    [ValidateSet("auto","mmap","none","mlock","mmap+mlock","dio")]
    [string]$LoadMode = "auto",    # 模型加载方式。默认 auto（=mmap，按需分页）。
                                   # 慢盘上 mmap 抖动导致卡顿时，用 none 整块读进内存。
    [switch]$Lan,                  # 让同一个 wifi / 局域网里的手机、平板也能连上用。
                                   # 不加这个开关时只监听 127.0.0.1，同网段的人碰不到。
    [string]$ApiKey = "",          # -Lan 时给接口加一把钥匙。留空 = 不设，
                                   # 同一个网络里任何人都能用（家里 wifi 通常没问题）。
    [int]$MaxRetry = 2,            # 显存/内存不足时自动降档重试的次数上限。
                                   # 0 = 不重试，直接报错退出。
    [switch]$NoSystemPrompt,       # 关掉默认的中文系统提示（模型会按自己的脾气挑语言）
    [string]$SystemPrompt = "",    # 自定义默认系统提示。留空 = 用内置那句"始终用简体中文"。
                                   # 只在客户端自己没发 system 消息时补上；客户端带了就听客户端的。
    [switch]$ReadFiles,            # 让 AI 能自己读本地文件（只读：读文件、找文件、搜内容、看环境）。
                                   # 开着的时候它才能回答"这个文件里写了什么"，否则只能靠猜。
    [switch]$AllowWrite,           # 在 -ReadFiles 之上再放开写文件、改文件、执行命令。
                                   # 等于把这台电脑交给模型，只在隔离的机器上用。
    [string]$ToolDir = "",         # AI 能碰的目录。留空 = U 盘上的 workspace\。
                                   # 只有这个目录里的文件能被读到，外面的碰不到。
                                   # 目录名必须是纯英文数字，原因见下面 6.4。
    [switch]$NoSnapshot,           # -AllowWrite 时默认会把 workspace\ 备份一份、关掉时
                                   # 列出 AI 新写/改/删了哪些文件。这个开关把备份省掉
                                   # （仍会列出改动，只是不能回退）。
    # ---- 采样参数。留空 = 读 参数设置.txt，再没有就用内置默认 ----
    # 用 $PSBoundParameters 判断"有没有给"，不能拿 0 或 -1 当哨兵：
    # temp=0 是合法值（要确定性输出的人天天用），拿 0 当"没设"会让 --temp 0 静默失效。
    [double]$Temp = 0,             # 0~2    越低越稳、越高越发散
    [double]$TopP = 0,             # 0~1
    [int]$TopK = -1,               # 0~200  0 = 关掉
    [double]$MinP = 0,             # 0~1
    [double]$RepeatPenalty = 0,    # 0.5~2  1.0 = 关掉
    [int]$NPredict = 0,            # -1 = 不限；1~32768 = 每条回答最多这么多 token
    [switch]$CheckUpdate           # 只查有没有新版本，不启动
)

$AppVersion = "1.5.0"

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
try { $Host.UI.RawUI.WindowTitle = "U盘 AI 便携版 - MiMo 9B" } catch { }

# ---------------- 路径（全部相对 U 盘） ----------------
$Root = $PSScriptRoot
if (-not $Root) { $Root = Split-Path -Parent $MyInvocation.MyCommand.Definition }
if (-not $Root) { $Root = (Get-Location).Path }
$Root = $Root.TrimEnd('\')

# ---------------- 端口可以由 U 盘根目录的 端口设置.txt 覆盖 ----------------
# 高级选项.bat 的 [16] 写这个文件。命令行 -Port 仍然优先 —— 临时指定不该被动过的
# 文件悄悄盖掉。放在这里是因为下面的 $Root 才知道文件在哪，而端口到 6.x 才用。
#
# 注意别和 logs\端口.txt 搞混：那个是**输出** —— 8080 被占用时启动器自动换号，
# 换到哪写在哪（Open-WebUI 读它）。这个 端口设置.txt 是**输入**，写的是你想要哪个号。
$portFrom = ""
if ($PSBoundParameters.ContainsKey('Port')) {
    $portFrom = "命令行 -Port"
} else {
    $portFile = Join-Path $Root "端口设置.txt"
    if (Test-Path $portFile) {
        try {
            $pt = (Get-Content $portFile -Raw -Encoding UTF8).Trim()
            $pn = 0
            if ([int]::TryParse($pt, [ref]$pn) -and $pn -ge 1024 -and $pn -le 65535) {
                $Port = $pn
                $portFrom = "端口设置.txt"
            } else {
                Write-Host "  [注意] 端口设置.txt 里不是合法端口（要 1024~65535），这次仍用 $Port" -ForegroundColor Yellow
            }
        } catch {
            # 文件读不动就当没设过，不该拦住启动
        }
    }
}

$DirModels = Join-Path $Root "models"
$DirLlama  = Join-Path $Root "llama.cpp"
$DirLog    = Join-Path $Root "logs"
# 写保护的 U 盘 / 只读挂载的盘上建不出目录。日志只是附带品，
# 不该因为写不进日志就让启动器死在第一屏 —— 建不出来就退回系统临时目录。
try {
    if (-not (Test-Path $DirLog)) { New-Item -ItemType Directory -Force -Path $DirLog | Out-Null }
} catch {
    $DirLog = Join-Path $env:TEMP "portable-ai-usb-logs"
    if (-not (Test-Path $DirLog)) { New-Item -ItemType Directory -Force -Path $DirLog | Out-Null }
}

function Head($t) {
    Write-Host ""
    Write-Host ("=" * 64) -ForegroundColor DarkCyan
    Write-Host ("  " + $t) -ForegroundColor Cyan
    Write-Host ("=" * 64) -ForegroundColor DarkCyan
}

# 等一个回车。stdin 被重定向时（自动化测试、计划任务）Read-Host 会抛
# "PowerShell 处于非交互模式" 并让整个脚本以退出码 1 死掉 —— 这里兜住它。
function Wait-Enter([string]$Msg = "  回车退出") {
    try {
        if ([Console]::IsInputRedirected) { return }
    } catch { return }
    try { Read-Host $Msg } catch { }
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
if (-not (Test-Path $DirModels)) {
    Write-Host "  [错误] 找不到 models 目录 —— 这支盘还没准备好" -ForegroundColor Red
    Write-Host "         期望位置：$DirModels" -ForegroundColor DarkGray
    Write-Host "         该怎么办：" -ForegroundColor Gray
    Write-Host "           1. 确认这支盘插好了，盘符确实是 $($Root.Substring(0,2))" -ForegroundColor Gray
    Write-Host "           2. 新建 models\ 目录，把 .gguf 模型文件放进去" -ForegroundColor Gray
    Write-Host "           3. 还没下过模型的话，运行 tools\准备U盘.ps1 自动组装" -ForegroundColor Gray
    Wait-Enter; exit 1
}

$allModels = @(Get-ChildItem $DirModels -Filter "*.gguf" -File -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -notlike "mmproj-*" })
if ($allModels.Count -eq 0) {
    Write-Host "  [错误] models 目录里没有模型 —— 一个 .gguf 都没有" -ForegroundColor Red
    Write-Host "         位置：$DirModels" -ForegroundColor DarkGray
    Write-Host "         模型是单独下载的（约 6.4 GB），不在 Git 仓库里。" -ForegroundColor Gray
    Write-Host "         运行 tools\准备U盘.ps1 可以自动下载并校验，或者手动下好放进 models\。" -ForegroundColor Gray
    Wait-Enter; exit 1
}

$pickFile = Join-Path $DirModels "当前模型.txt"
$model    = $null
$source   = ""

# 把一个"大概的名字"解析成 models\ 里的具体文件：
#   ① 完整文件名精确匹配
#   ② 补上 .gguf 后精确匹配
#   ③ 不区分大小写的子串匹配 —— 只有唯一命中才算数
# 返回 @{ File = <FileInfo 或 $null>; Candidates = @() }
function Resolve-ModelFile {
    param([string]$Name, [object[]]$Pool)
    if (-not $Name) { return @{ File = $null; Candidates = @() } }

    $hit = @($Pool | Where-Object { $_.Name -eq $Name })
    if ($hit.Count -eq 0) { $hit = @($Pool | Where-Object { $_.Name -eq "$Name.gguf" }) }
    if ($hit.Count -eq 0) {
        $hit = @($Pool |
                 Where-Object { $_.Name.IndexOf($Name, [StringComparison]::OrdinalIgnoreCase) -ge 0 } |
                 Sort-Object Length -Descending)
    }
    if ($hit.Count -eq 1) { return @{ File = $hit[0]; Candidates = @() } }
    return @{ File = $null; Candidates = $hit }
}

function Show-ModelList($headline) {
    Write-Host "  [错误] $headline" -ForegroundColor Red
    Write-Host "         models 目录里现有：" -ForegroundColor DarkGray
    foreach ($m in ($allModels | Sort-Object Length -Descending)) {
        Write-Host ("           {0}  ({1:N2} GB)" -f $m.Name, ($m.Length / 1GB)) -ForegroundColor DarkGray
    }
    Write-Host "         文件名可以只写一部分，例如 MiMo 或 Qwen3-4B" -ForegroundColor DarkGray
}

if ($ModelName) {
    $r = Resolve-ModelFile -Name $ModelName -Pool $allModels
    if (-not $r.File) {
        if ($r.Candidates.Count -gt 1) {
            Show-ModelList "「$ModelName」匹配到多个模型（$($r.Candidates.Count) 个），说不准用哪个"
        } else {
            Show-ModelList "models 目录里找不到叫「$ModelName」的模型"
        }
        Wait-Enter; exit 1
    }
    $model  = $r.File
    $source = "启动参数 -ModelName 指定"
} elseif (Test-Path $pickFile) {
    $want = Get-Content $pickFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if ($want) { $want = $want.Trim() }
    if ($want) {
        $r = Resolve-ModelFile -Name $want -Pool $allModels
        if ($r.File) { $model = $r.File; $source = "models\当前模型.txt 指定" }
        elseif ($r.Candidates.Count -gt 1) { Write-Host "  [注意] 当前模型.txt 里的「$want」匹配到多个模型，说不准用哪个，改回自动选最大的。" -ForegroundColor Yellow }
        else { Write-Host "  [注意] 当前模型.txt 里写的「$want」在 models\ 里找不到，改回自动选最大的。" -ForegroundColor Yellow }
    }
}

if (-not $model) {
    $model  = $allModels | Sort-Object Length -Descending | Select-Object -First 1
    $source = "自动（体积最大）"
}

# ---------------- 1.5 多模态投影文件（视觉能力）----------------
# 引擎自己有 --mmproj-auto（默认开），但官方说明是"配合 -hf 拉远端模型时有用"；
# 本盘用 -m 指定本地文件，自动检测不会生效。更要紧的是，引擎在找不到投影文件时
# 有"自动下载"的路径 —— 那会联网，直接违背"零联网"承诺。
# 所以这里两条路都写死：找到就显式指过去，没找到就显式关掉，不给引擎自己决定的机会。
$mmproj = @(Get-ChildItem $DirModels -Filter "mmproj-*.gguf" -File -ErrorAction SilentlyContinue |
            Sort-Object Length -Descending)
if ($mmproj.Count -gt 0) { $mmproj = $mmproj[0] } else { $mmproj = $null }

$modelGB = [math]::Round($model.Length / 1GB, 2)
$alias   = [IO.Path]::GetFileNameWithoutExtension($model.Name)
Write-Host "  模型     : $($model.Name)" -ForegroundColor Green
Write-Host "  模型大小 : $modelGB GB"
if ($mmproj) {
    Write-Host "  视觉能力 :  开  ($($mmproj.Name))" -ForegroundColor Green
} else {
    Write-Host "  视觉能力 :  关  (models\ 里没有 mmproj-*.gguf)" -ForegroundColor DarkGray
}
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

# ---------------- 1.5 这支 U 盘有多快 ----------------
# 为什么要测：模型是 mmap 按需从 U 盘读的。同一支盘插在 USB 2.0 口上，
# 加载时间会从十几秒掉到几分钟。测出来才能给出"要等多久"的实话，
# 也才能在盘太慢的时候直接告诉用户换口/换盘，而不是让人对着黑屏猜。
# 无缓冲读的底座。FILE_FLAG_NO_BUFFERING 绕过 Windows 的系统缓存，
# 直接向设备要数据 —— 这才是"这支盘有多快"的唯一真话。
# 代价：读缓冲区的地址和文件偏移都必须按 4096 对齐，所以手工分配再对齐。
$script:RawDiskCs = @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class PsRawDisk
{
    const uint GENERIC_READ          = 0x80000000;
    const uint FILE_SHARE_READ       = 0x00000001;
    const uint FILE_SHARE_WRITE      = 0x00000002;
    const uint OPEN_EXISTING         = 3;
    const uint FILE_FLAG_NO_BUFFERING = 0x20000000;

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern SafeFileHandle CreateFileW(string lpFileName, uint dwDesiredAccess,
        uint dwShareMode, IntPtr lpSecurityAttributes, uint dwCreationDisposition,
        uint dwFlagsAndAttributes, IntPtr hTemplateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool ReadFile(SafeFileHandle hFile, IntPtr lpBuffer,
        uint nNumberOfBytesToRead, out uint lpNumberOfBytesRead, IntPtr lpOverlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetFilePointerEx(SafeFileHandle hFile, long liDistanceToMove,
        out long lpNewFilePointer, uint dwMoveMethod);

    public static SafeFileHandle Open(string path)
    {
        return CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
            IntPtr.Zero, OPEN_EXISTING, FILE_FLAG_NO_BUFFERING, IntPtr.Zero);
    }

    public static long Seek(SafeFileHandle h, long pos)
    {
        long got;
        return SetFilePointerEx(h, pos, out got, 0) ? got : -1;
    }

    public static int Read(SafeFileHandle h, IntPtr buf, int count)
    {
        uint got;
        return ReadFile(h, buf, (uint)count, out got, IntPtr.Zero) ? (int)got : -1;
    }

    public static IntPtr AllocAligned(int size, out IntPtr raw)
    {
        raw = Marshal.AllocHGlobal(size + 4096);
        return new IntPtr((raw.ToInt64() + 4095L) & ~4095L);
    }

    public static void Free(IntPtr raw) { if (raw != IntPtr.Zero) Marshal.FreeHGlobal(raw); }
}
'@

function Measure-DiskReadRaw {
    param([string]$Path)

    $r = [ordered]@{ SeqMBps = 0.0; RandIOPS = 0; RandMBps = 0.0; Samples = @(); Error = $null; Raw = $true; Truncated = $false }
    $h = $null; $rawSeq = [IntPtr]::Zero; $bufSeq = [IntPtr]::Zero
    $rawBlk = [IntPtr]::Zero; $bufBlk = [IntPtr]::Zero
    try {
        if (-not ("PsRawDisk" -as [type])) {
            Add-Type -TypeDefinition $script:RawDiskCs -Language CSharp -ErrorAction Stop
        }
        $h = [PsRawDisk]::Open($Path)
        if ($null -eq $h -or $h.IsInvalid) {
            throw ("CreateFile 失败，错误码 " + [Runtime.InteropServices.Marshal]::GetLastWin32Error())
        }
        $len = (Get-Item -LiteralPath $Path).Length

        # 顺序读：文件深处两个随机位置各读 32 MB，取较慢的一次。
        # 无缓冲之后不再需要"往深处读躲缓存"—— 每次读都是真盘速 ——
        # 但取两次里较慢的那个仍然有用：能躲开闪存偶尔的快突发。
        $blockMB = 32
        $want    = $blockMB * 1MB
        $bufSeq  = [PsRawDisk]::AllocAligned($want, [ref]$rawSeq)
        if ($len -gt ($want * 4)) {
            $rnd   = New-Object System.Random
            $spots = @((0.15 + $rnd.NextDouble() * 0.20),
                       (0.50 + $rnd.NextDouble() * 0.30))
            foreach ($pct in $spots) {
                $pos = [long](($len * $pct) / 4096) * 4096      # 偏移也要 4096 对齐
                if ([PsRawDisk]::Seek($h, $pos) -lt 0) { throw "SetFilePointerEx 失败（偏移 $pos）" }
                $got = 0
                $sw  = [System.Diagnostics.Stopwatch]::StartNew()
                while ($got -lt $want) {
                    $n = [PsRawDisk]::Read($h, $bufSeq, [math]::Min(1MB, $want - $got))
                    if ($n -le 0) { break }
                    $got += $n
                    # 时间闸：这一段只是启动前给用户一句"大概要等多久"，不该在慢盘上
                    # 反过来让人多等十几秒。3 秒到点就用手上已读到的字节数算均值 ——
                    # 读了多少、花了多久都还是真数，只是样本小一点。
                    if ($sw.Elapsed.TotalSeconds -gt 3.0) { $r.Truncated = $true; break }
                }
                $sw.Stop()
                $sec = $sw.Elapsed.TotalSeconds
                if ($sec -gt 0 -and $got -gt 0) {
                    $r.Samples += [math]::Round(($got / 1MB) / $sec, 1)
                }
                if ($r.Samples.Count -eq 1 -and $r.Samples[0] -lt 40) { break }
            }
        }
        if ($r.Samples.Count -gt 0) {
            $r.SeqMBps = ($r.Samples | Measure-Object -Minimum).Minimum
        }

        # 随机 4 KB × 128 —— 闪存盘真正的瓶颈就在这里（常见只有 1~5 MB/s）。
        # 无缓冲的 4K 读等于直接打设备队列，得到的 IOPS 才是插上后 mmap 会遇到的数。
        if ($len -gt 64MB) {
            $bufBlk = [PsRawDisk]::AllocAligned(4096, [ref]$rawBlk)
            $rnd2   = New-Object System.Random
            $base   = 64MB
            $span   = $len - $base - 4096
            $sw2    = [System.Diagnostics.Stopwatch]::StartNew()
            $miss   = 0
            $done   = 0
            for ($i = 0; $i -lt 128; $i++) {
                # 时间闸同上：慢盘上这 128 次随机读能拖到十几秒。到点就用已完成的次数
                # 折算 IOPS —— 完成几次、花了多久都是真数，只是样本小一点。
                if ($sw2.Elapsed.TotalSeconds -gt 1.5) { $r.Truncated = $true; break }
                $pos = $base + [long](($rnd2.NextDouble() * $span) / 4096) * 4096
                if ([PsRawDisk]::Seek($h, $pos) -lt 0) { break }
                if ([PsRawDisk]::Read($h, $bufBlk, 4096) -lt 0) { $miss++ }
                $done++
            }
            $sw2.Stop()
            $sec = $sw2.Elapsed.TotalSeconds
            if ($sec -gt 0 -and $done -gt 0 -and $miss -eq 0) {
                $r.RandIOPS = [math]::Round($done / $sec, 0)
                $r.RandMBps = [math]::Round(($done * 4KB / 1MB) / $sec, 2)
            }
        }
    } catch {
        $r.Error = $_.Exception.Message
        $r.SeqMBps = 0.0
    } finally {
        if ($h) { $h.Dispose() }
        # Add-Type 失败时 [PsRawDisk] 这个类型根本不存在，这时直接调 Free 会再抛一个
        # "找不到类型 PsRawDisk"，把真正的错误盖掉，而且这个函数永远返回不到 ——
        # 调用方本该看到的"退回带缓冲读"就再也不会发生。
        if ("PsRawDisk" -as [type]) {
            [PsRawDisk]::Free($rawSeq)
            [PsRawDisk]::Free($rawBlk)
        }
    }
    return $r
}

# 为什么还留着一份带缓冲的实现：
#   FILE_FLAG_NO_BUFFERING 在少数环境下会直接失败（盘被独占、部分虚拟盘 / 网络盘、
#   非 4096 扇区）。那种时候退回带缓冲读，至少还能测个数 —— 只是可能吃到系统缓存，
#   所以结果上打 Raw=$false，让 Show-DiskReport 去判断和提示。
function Measure-DiskReadBuffered {
    param([string]$Path)

    $r = [ordered]@{ SeqMBps = 0.0; RandIOPS = 0; RandMBps = 0.0; Samples = @(); Error = $null; Raw = $false; Truncated = $false }
    $fs = $null
    try {
        $fs  = [System.IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $len = $fs.Length

        $buf     = New-Object byte[] (1MB)
        $blockMB = 32
        if ($len -gt ($blockMB * 1MB * 4)) {
            $rndOff = New-Object System.Random
            $spots  = @((0.15 + $rndOff.NextDouble() * 0.20),
                        (0.50 + $rndOff.NextDouble() * 0.30))
            foreach ($pct in $spots) {
                $fs.Position = [long]($len * $pct)
                $got  = 0
                $want = $blockMB * 1MB
                $sw   = [System.Diagnostics.Stopwatch]::StartNew()
                while ($got -lt $want) {
                    $n = $fs.Read($buf, 0, $buf.Length)
                    if ($n -le 0) { break }
                    $got += $n
                }
                $sw.Stop()
                $sec = $sw.Elapsed.TotalSeconds
                if ($sec -gt 0 -and $got -gt 0) {
                    $r.Samples += [math]::Round(($got / 1MB) / $sec, 1)
                }
                if ($r.Samples.Count -eq 1 -and $r.Samples[0] -lt 40) { break }
            }
        }
        if ($r.Samples.Count -gt 0) {
            $r.SeqMBps = ($r.Samples | Measure-Object -Minimum).Minimum
        }

        # 种子必须每次不同：写死种子会让每回挑中同一批偏移，第二次跑全命中系统缓存。
        if ($len -gt 64MB) {
            $blk  = New-Object byte[] (4KB)
            $rnd  = New-Object System.Random
            $base = 64MB
            $span = $len - $base - $blk.Length
            $sw2  = [System.Diagnostics.Stopwatch]::StartNew()
            $done = 0
            for ($i = 0; $i -lt 128; $i++) {
                if ($sw2.Elapsed.TotalSeconds -gt 1.5) { $r.Truncated = $true; break }
                $fs.Position = $base + [long]($rnd.NextDouble() * $span)
                [void]$fs.Read($blk, 0, $blk.Length)
                $done++
            }
            $sw2.Stop()
            $sec = $sw2.Elapsed.TotalSeconds
            if ($sec -gt 0 -and $done -gt 0) {
                $r.RandIOPS = [math]::Round($done / $sec, 0)
                $r.RandMBps = [math]::Round(($done * 4KB / 1MB) / $sec, 2)
            }
        }
    } catch {
        $r.Error = $_.Exception.Message
    } finally {
        if ($fs) { $fs.Dispose() }
    }
    return $r
}

# 对外只暴露这一个。优先无缓冲；无缓冲不可用或读不出数，才退回带缓冲。
function Measure-DiskRead {
    param([string]$Path)

    $raw = Measure-DiskReadRaw -Path $Path
    if ($raw.SeqMBps -gt 0) { return $raw }

    $buf = Measure-DiskReadBuffered -Path $Path
    # 退回路径也失败时，把无缓冲那边的错误留下来 —— 那才是真正的原因
    if ($buf.SeqMBps -le 0 -and -not $buf.Error) { $buf.Error = $raw.Error }
    return $buf
}

function Get-EstimateSeconds {
    param($Disk, [long]$ModelBytes)
    if ($Disk.SeqMBps -le 0) { return 0 }
    # 读完还要初始化后端：实测 CUDA 后端初始化约 5 秒，算进去更接近真实等待
    return [int][math]::Ceiling(($ModelBytes / 1MB) / $Disk.SeqMBps) + 5
}

function Show-DiskReport {
    param($Disk, [int]$EstSec, [double]$ModelGB)

    # 无缓冲读的结果不可能是缓存 —— 那是直接问设备要的数。
    # 只有退回带缓冲读（Raw=$false）时，>1500 MB/s 才只可能是系统缓存。
    $cached = ((-not $Disk.Raw) -and ($Disk.SeqMBps -ge 1500))

    $verdict, $color = switch ($true) {
        ($cached)               { "内存缓存命中，不是真实盘速", "Yellow"; break }
        ($Disk.SeqMBps -ge 250) { "很快（移动固态级别）", "Green";      break }
        ($Disk.SeqMBps -ge 120) { "正常（USB 3.x 闪存盘）", "Green";    break }
        ($Disk.SeqMBps -ge 60)  { "偏慢", "Yellow";                     break }
        ($Disk.SeqMBps -gt 0)   { "很慢", "Red";                        break }
        default                 { "测不出来", "DarkGray" }
    }

    Write-Host ""
    Write-Host "  这支 U 盘：" -ForegroundColor DarkCyan
    if ($Disk.Error) {
        Write-Host "    测速失败（不影响使用）：$($Disk.Error)" -ForegroundColor DarkGray
        return
    }
    Write-Host ("    顺序读    {0,7:N1} MB/s    {1}" -f $Disk.SeqMBps, $verdict) -ForegroundColor $color
    if ($Disk.RandIOPS -gt 0) {
        Write-Host ("    随机 4K   {0,7:N0} IOPS   ({1:N2} MB/s)" -f $Disk.RandIOPS, $Disk.RandMBps) -ForegroundColor DarkGray
    }
    if ($Disk.Raw) {
        Write-Host "    （绕过系统缓存的实测值，就是这支盘的本事）" -ForegroundColor DarkGray
    }
    if ($Disk.Truncated) {
        Write-Host "    （这支盘慢，测到时间上限就收工了 —— 数字取自已经读完的那部分，够估时间）" -ForegroundColor DarkGray
    }
    if ($cached) {
        Write-Host ""
        Write-Host "    这份模型已经被系统缓存过，上面的数字来自内存，不是这支盘的本事。" -ForegroundColor Yellow
        # 缓存命中时给不出真实速度，但上次测到的真实值还在 —— 比什么都说不出强
        $recall = Join-Path $DirLog "上次测速.txt"
        if (Test-Path $recall) {
            $line = Get-Content $recall -Encoding UTF8 -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($line) { Write-Host "    这支盘上次的真实测速：$line" -ForegroundColor Cyan }
        } else {
            Write-Host "    重启电脑后再测一次，就能得到真实数字。" -ForegroundColor Yellow
        }
        Write-Host "    分档参考：插到一台没跑过它的电脑上大概要等多久，见 docs/硬件与性能.md" -ForegroundColor DarkGray
        return
    }
    if ($EstSec -gt 0) {
        Write-Host ("    预计加载 {0} GB 模型约需 {1} 秒" -f $ModelGB, $EstSec) -ForegroundColor Cyan
    }
    # 真实测速：存一份，下次这份模型被缓存时至少能回看
    try {
        [System.IO.File]::WriteAllText(
            (Join-Path $DirLog "上次测速.txt"),
            ("{0:N1} MB/s · 随机4K {1:N0} IOPS · 预计 {2} 秒 · {3}" -f `
                $Disk.SeqMBps, $Disk.RandIOPS, $EstSec, (Get-Date -Format "yyyy-MM-dd HH:mm")),
            (New-Object System.Text.UTF8Encoding $false))
    } catch { }
    if ($Disk.SeqMBps -lt 60) {
        Write-Host ""
        Write-Host "    慢的常见原因：插在了 USB 2.0 口上，或者这是一支低速闪存盘。" -ForegroundColor Yellow
        Write-Host "    先换个蓝色的 USB 3.0 口重插试试。还慢的话见 docs/硬件与性能.md" -ForegroundColor Yellow
    }
}

if ($Bench) {
    Head "测一下这支 U 盘的速度"
    Write-Host "  测试文件 : $($model.Name)  ($modelGB GB)"
    Write-Host "  绕过系统缓存真读一遍，最多几秒（盘特别慢会提前收工）"
    Write-Host "  （绕过系统缓存读，测的是这支盘本身）" -ForegroundColor DarkGray
    $d = Measure-DiskRead -Path $model.FullName
    Show-DiskReport -Disk $d -EstSec (Get-EstimateSeconds -Disk $d -ModelBytes $model.Length) -ModelGB $modelGB
    Write-Host ""
    Wait-Enter "  回车继续"
    exit 0
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
    Wait-Enter; exit 1
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

# ---- -LoadMode 兜底开关：none / mlock 都要整份模型进内存，装不下就别用 ----
$loadNote = $null
if ($LoadMode -in @("none", "mlock", "mmap+mlock")) {
    if ($ramGB -gt 0 -and $ramGB -lt ($modelGB + 1.5)) {
        $loadNote = "内存只有 $ramGB GB，装不下 $modelGB GB 的模型加运行开销 —— 加载方式已改回 auto（mmap 按需分页）。"
        $LoadMode = "auto"
    }
}

# ---------------- 5.9 -Lan：找出这台电脑在局域网里的地址 ----------------
# 只认真正连了路由器（有默认网关）、又不是回环或 169.254 自动私有地址的网卡。
# 找不到就别假装能连 —— 宁可说清楚"只能本机用"，也不要打印一个连不上的地址。
function Get-LanIP {
    try {
        foreach ($ni in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            if ($ni.OperationalStatus -ne "Up") { continue }
            if ($ni.NetworkInterfaceType -eq "Loopback") { continue }
            $props = $ni.GetIPProperties()
            if (-not $props.GatewayAddresses -or $props.GatewayAddresses.Count -eq 0) { continue }
            foreach ($ua in $props.UnicastAddresses) {
                if ($ua.Address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { continue }
                $s = $ua.Address.ToString()
                if ($s.StartsWith("169.254.")) { continue }
                return $s
            }
        }
    } catch { }
    return $null
}

$lanArg = "127.0.0.1"
$lanIP  = $null
if ($Lan) {
    $lanIP = Get-LanIP
    if ($lanIP) { $lanArg = "127.0.0.1,$lanIP" }
}

# ---------------- 5.95 默认系统提示：借模型自己那份模板，只在开头补一条 system ----------------
# 引擎没有"默认 system"这种参数，模型的模板里也没有对应变量 —— 唯一可行的办法是
# 拿模型自己那份模板改三行（见 templates\*.jinja）。所以匹配不上就绝不硬套：
# 换了模型还拿旧格式的模板去喂，输出会整段烂掉。
function Get-ModelTemplate([string]$ModelFileName) {
    $dir = Join-Path $Root "templates"
    if (-not (Test-Path $dir)) { return $null }
    $base = [System.IO.Path]::GetFileNameWithoutExtension($ModelFileName)
    try {
        # 取"最长的那份"，和全仓模型名匹配一条规矩：有了 MiMo.jinja 又有 MiMo-V2.6-...jinja 时，
        # 按 Get-ChildItem 的字母序返回会听天由命。注意这里不能用 Sort-Object Length —— FileInfo 的
        # Length 是文件字节数，不是文件名长度，会按模板大小排。
        $hit = Get-ChildItem $dir -Filter "*.jinja" -File -ErrorAction SilentlyContinue |
            Where-Object {
                $base.StartsWith([System.IO.Path]::GetFileNameWithoutExtension($_.Name),
                                 [System.StringComparison]::OrdinalIgnoreCase)
            } |
            Sort-Object @{ Expression = { [System.IO.Path]::GetFileNameWithoutExtension($_.Name).Length } } -Descending |
            Select-Object -First 1
        if ($hit) { return $hit.FullName }
    } catch { }
    return $null
}

# 这句是测出来的，不是想出来的。同一个模型、同一个问题，六种说法各跑 2~4 次：
#   「你必须始终使用简体中文回答，无论用户用什么语言提问。」        → 全英文
#   「始终用简体中文回答。」                                  → 全英文
#   「无论用户用什么语言提问，你都只能用简体中文回答，不要使用英文。」 → 全英文
#   「你是中文助手，回答一律使用简体中文，禁止英文。」            → 全英文
#   「优先用简体中文回答；用户明确指定别的语言时听用户的。」        → 全英文
#   「中文回答。回答必须全部是简体中文，不要出现英文单词。」        → 中文 3/5 ✓
# 这一句还**不会跟用户抢**：用户明说 "answer in English" 时它照样用英文（0/2 中文）。
# 9B 模型对客气的长句基本不理会，只对短、直、动词开头的祈使句有反应。
#
# 但它和「让 AI 读文件」会打架，2026-10-17 测出来的：
#   用户问「项目.txt 里写的交付日期是哪天？直接告诉我日期。」时，这句 0/5 不调工具
#   —— 后半截在叫它"别查，直接说"，它就真不查，然后编一句"我还没看到这个文件"。
#   换成下面这句，同一条问题 5/5 都调工具，语言那关一分没掉（还是 3/5）。
# 只加一句"需要读文件就直接调工具"就够 —— 它把"别查"那句顶回去了。
# 不改的话，装了 [15] 读文件功能的 U 盘，用户越催"直接告诉我"，越容易拿到编的答案。
$DefaultChinesePrompt = "中文回答。不要出现英文单词。需要读文件就直接调工具。"
# 想让「改系统提示」能落盘，就得有个文件 —— U 盘根目录的 系统提示.txt。
# 优先级：命令行 -SystemPrompt > 系统提示.txt > 内置那句。
# -NoSystemPrompt 压过一切（那是明确说"别注入"）。
$SysPromptFile = Join-Path $Root "系统提示.txt"
$filePrompt = ""
if (Test-Path $SysPromptFile) {
    try { $filePrompt = (Get-Content $SysPromptFile -Raw -Encoding UTF8).Trim() } catch { $filePrompt = "" }
}

if ($NoSystemPrompt)   { $sysPrompt = "" }
elseif ($SystemPrompt) { $sysPrompt = $SystemPrompt }
elseif ($filePrompt)   { $sysPrompt = $filePrompt }
else                   { $sysPrompt = $DefaultChinesePrompt }

$tplFile  = $null
$tplNote  = $null
if ($sysPrompt) {
    $tplFile = Get-ModelTemplate $model.Name
    if (-not $tplFile) {
        $tplNote = "想让模型默认说中文，但 templates\ 里没有匹配 $($model.Name) 的模板 —— 本次不注入，模型自己挑语言。"
        $sysPrompt = ""
    }
}

# ---------------- 6.3 采样参数 ----------------
# 这些以前是写死在 Build-Args 里的（--temp 0.6 / --top-p 0.95 ...）。值本身是调过的，
# 但用户改不了：「回答太啰嗦」「太发散」「老是重复」只能忍着。改成两条路可配。
#
# 优先级：命令行 > 参数设置.txt > 内置默认。
#
# 范围校验放在这里，不扔给引擎：引擎收到离谱的值（比如 temp=-1）是直接退出，
# 用户看到的只有一行 "exited"，没有线索。这里拦住并说清楚哪个键、错在哪。
$ParamDefaults = [ordered]@{
    temp           = 0.6
    top_p          = 0.95
    top_k          = 20
    min_p          = 0.0
    repeat_penalty = 1.1
    n_predict      = -1
}
$ParamRanges = @{
    temp           = @(0.0, 2.0)
    top_p          = @(0.0, 1.0)
    top_k          = @(0, 200)
    min_p          = @(0.0, 1.0)
    repeat_penalty = @(0.5, 2.0)
    n_predict      = @(-1, 32768)
}
$ParamFile = Join-Path $Root "参数设置.txt"
$sample = [ordered]@{}
foreach ($k in $ParamDefaults.Keys) { $sample[$k] = $ParamDefaults[$k] }
$sampleFrom = @{}
$sampleNote = @()

# 命令行走 $PSBoundParameters，不走哨兵值。见参数声明处的说明。
$cliMap = [ordered]@{
    temp = 'Temp'; top_p = 'TopP'; top_k = 'TopK'
    min_p = 'MinP'; repeat_penalty = 'RepeatPenalty'; n_predict = 'NPredict'
}
foreach ($k in $cliMap.Keys) {
    if ($PSBoundParameters.ContainsKey($cliMap[$k])) {
        $sample[$k] = $PSBoundParameters[$cliMap[$k]]
        $sampleFrom[$k] = "命令行 -$($cliMap[$k])"
    }
}

if (Test-Path $ParamFile) {
    try {
        $ln = 0
        foreach ($raw in [IO.File]::ReadAllLines($ParamFile)) {
            $ln++
            $line = $raw.Trim()
            if (-not $line) { continue }
            if ($line.StartsWith('#')) { continue }
            # 半角 = 或 : 或全角 ＝ 都认 —— 用户从聊天窗口复制参数时经常带全角
            $m = [regex]::Match($line, '^([A-Za-z_]+)\s*[=:＝：]\s*(.+)$')
            if (-not $m.Success) {
                $sampleNote += "参数设置.txt 第 $ln 行看不懂，跳过：$line"
                continue
            }
            $k = $m.Groups[1].Value.Trim().ToLower()
            $v = $m.Groups[2].Value.Trim()
            if (-not $ParamDefaults.Contains($k)) {
                $sampleNote += "参数设置.txt 第 $ln 行的键「$k」不认识，跳过（认识的：$($ParamDefaults.Keys -join ', ')）"
                continue
            }
            if ($sampleFrom.ContainsKey($k)) { continue }    # 命令行已经给了，文件不覆盖
            $num = 0.0
            $parsed = [double]::TryParse($v,
                [System.Globalization.NumberStyles]::Float,
                [System.Globalization.CultureInfo]::InvariantCulture, [ref]$num)
            if (-not $parsed) {
                $sampleNote += "参数设置.txt 第 $ln 行「$k = $v」不是数字，跳过"
                continue
            }
            $lo = $ParamRanges[$k][0]; $hi = $ParamRanges[$k][1]
            if ($num -lt $lo -or $num -gt $hi) {
                $sampleNote += "参数设置.txt 第 $ln 行「$k = $v」超出范围（$lo ~ $hi），跳过"
                continue
            }
            $sample[$k] = $num
            $sampleFrom[$k] = "参数设置.txt"
        }
    } catch {
        # 读不动就用默认值，不该拦住启动
    }
}

# 传给引擎的数字必须用不变文化格式。中文区域的小数点也是 "."，但别的区域未必，
# 拼成 "0,6" 引擎会当成两个参数 —— 这种错只在某些机器上出现，最难查。
function Inv([double]$v) { return $v.ToString([System.Globalization.CultureInfo]::InvariantCulture) }

# ---------------- 6.4 让 AI 读文件 ----------------
# 引擎自己的内置工具。开了以后：客户端带 tools 数组发请求 → 模型回一个 tool_call →
# 客户端把 tool_call 发给引擎的 POST /tools → **引擎**在自己的进程里执行、把结果读回给模型。
# 所以能读到哪些文件，由引擎的工作目录决定 —— 这是唯一的边界，必须钉死在一个目录上。
#
# 这个目录名必须是纯 ASCII。实测（引擎 cuda13 版）：
#   CWD = E:\工作区   →  read_file 能读出来（走宽字符路径），
#                        file_glob_search / grep_search 一律 500：
#                        "No mapping for the Unicode character exists in the target multi-byte code page."
#   CWD = E:\wsA     →  四个工具全部正常，文件名叫「项目.txt」也照样能列能搜
# 也就是说：引擎列举目录那一步走的是窄字符 Win32 API，路径里有非 ASCII 就崩。
# 这是引擎的毛病，不是我们的，但落哪个目录是我们定的 —— 所以默认用英文名绕开它。
# 目录里面的**文件名**随便用中文，不受影响。
#
# 默认只开只读的四件。剩下的 write_file / edit_file / exec_shell_command 能改文件、
# 能执行命令，等于把这台电脑交出去，要人明确说 -AllowWrite 才放。
$toolsOn  = $ReadFiles -or $AllowWrite
# PowerShell 变量名不区分大小写：$ToolDir（参数）和 $toolDir（局部）是同一个变量。
# 下面一行的 $toolDir = $null 会把传进来的参数冲掉 —— 先把参数抄到另一个名字再清。
$toolWant = $ToolDir
$toolDir  = $null
$toolNote = $null
if ($toolsOn) {
    $want = if ($toolWant) { $toolWant } else { Join-Path $Root "workspace" }
    try {
        if (-not (Test-Path $want)) { New-Item -ItemType Directory -Force -Path $want | Out-Null }
        $toolDir = (Resolve-Path $want).Path
        $bad = [regex]::Match($toolDir, '[^\x20-\x7E]')
        if ($bad.Success) {
            $toolNote = "目录「$toolDir」的路径里有非英文字符，引擎会列不出文件（读单个文件仍可以）。" +
                        "建议换成纯英文路径，例如 $Root\workspace。"
        }
    } catch {
        $toolNote = "想让 AI 读文件，但建不出目录「$want」—— 本次不开启读文件。"
        $toolsOn = $false
    }
}

# 开了工具就补一句「环境是什么、该用哪个工具」。
# 实测依据：同一句「todo.txt 里有什么」，不补这句时模型先猜 /home/user/todo.txt、
# 再 `pwd && ls -la`、再 `find /`，5 次调用全废；补了以后 1 次 read_file 就拿到了。
# 改文件那半句更要紧：不点名它就会拿 exec_shell_command 去 echo 追加，
# 而那是 Windows cmd，中文落盘成 `'- ???? '`，文件直接被写坏。
# 只在开了工具时追加 —— 没工具时提"调工具"就是骗模型。
$ToolHint = "文件都在当前目录，路径直接写文件名就行。这个系统是 Windows。" +
            "改文件用 write_file 或 edit_file，不要用命令行改。"
if ($toolsOn -and $sysPrompt) {
    $sysPrompt = $sysPrompt + $ToolHint
}

# ---------------- 6.5 开了写权限时，让改动看得见 ----------------
# 只读是安全的一半；另一半是「它改了什么我能知道，还能退回去」。
# 以前 -AllowWrite 只能从命令行开，因为菜单里给一个数字就等于把电脑交出去。
# 加上下面这套以后，菜单里给入口是合理的：
#   1) 启动前把 workspace\ 里现有文件备份到 workspace\.backup\<时间戳>\
#   2) 关掉时比对哈希，打印 AI 新写/改/删了哪些
# 备份有上限：超过 500 个文件或 500 MB 就只备份前一部分并说明 —— 备份本身
# 不该把 U 盘塞满，也不该让启动卡几分钟。
$snapBefore = $null
$snapDir    = $null

# 目录指纹：相对路径 -> "字节数:修改时间"。
# 不用哈希：判断"变没变"够用，也不必把每个文件都完整读一遍。
function Get-FileStamp([string]$Dir) {
    $map = @{}
    if (-not $Dir) { return $map }
    if (-not (Test-Path -LiteralPath $Dir)) { return $map }
    foreach ($f in @(Get-ChildItem -LiteralPath $Dir -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        if ($f.FullName -like '*\.backup\*') { continue }
        $map[$f.FullName.Substring($Dir.Length).TrimStart('\')] = "$($f.Length):$($f.LastWriteTimeUtc.Ticks)"
    }
    return $map
}

if ($AllowWrite -and $toolDir) {
    try {
        $snapDir = Join-Path $toolDir (".backup\" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
        New-Item -ItemType Directory -Force -Path $snapDir | Out-Null
        $files = @(Get-ChildItem -LiteralPath $toolDir -Recurse -File -Force -ErrorAction SilentlyContinue |
                   Where-Object { $_.FullName -notlike '*\.backup\*' })
        $totalBytes = ($files | Measure-Object -Property Length -Sum).Sum
        if ($files.Count -gt 500 -or $totalBytes -gt 500MB) {
            Write-Host "  [注意] workspace\ 里文件太多（$($files.Count) 个 / $([math]::Round($totalBytes/1MB)) MB），" -ForegroundColor Yellow
            Write-Host "         只备份前 500 个且总量不超过 500 MB。没备份到的改动，关掉时只能看见、退不回。" -ForegroundColor Yellow
        }
        $copied = 0
        foreach ($f in $files) {
            if ($copied -ge 500) { break }
            $rel = $f.FullName.Substring($toolDir.Length).TrimStart('\')
            $dst = Join-Path $snapDir $rel
            $d   = Split-Path -Parent $dst
            if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
            Copy-Item -LiteralPath $f.FullName -Destination $dst -Force -ErrorAction SilentlyContinue
            $copied++
        }
        if ($copied -gt 0) {
            Write-Host "  已备份 :  $copied 个文件 -> $snapDir" -ForegroundColor DarkGray
        }
    } catch {
        $snapDir = $null
    }
    $snapBefore = Get-FileStamp $toolDir
}

# 关掉时调一次。引擎退出、Ctrl+C、异常退出都走这里（写在最外层，
# 因为 PowerShell 的 Ctrl+C 会直接终止管道，finally 未必跑得到 —— 所以这里
# 只是"正常情况下"的汇报，不作为安全保证）。
function Show-WorkspaceDiff {
    if (-not $AllowWrite -or -not $toolDir) { return }
    # 快照没拿到就退回用备份目录当基线 —— 备份落在盘上，比内存里的快照可靠。
    $before = $snapBefore
    if (($null -eq $before -or $before.Count -eq 0) -and $snapDir -and (Test-Path -LiteralPath $snapDir)) {
        $before = Get-FileStamp $snapDir
    }
    if ($null -eq $before) { $before = @{} }
    $after = Get-FileStamp $toolDir
    $new   = @($after.Keys  | Where-Object { -not $before.ContainsKey($_) })
    $gone  = @($before.Keys | Where-Object { -not $after.ContainsKey($_) })
    $edit  = @($after.Keys  | Where-Object { $before.ContainsKey($_) -and $before[$_] -ne $after[$_] })
    if ($new.Count + $gone.Count + $edit.Count -eq 0) {
        Write-Host "  AI 没有改动 workspace\ 里的任何文件。" -ForegroundColor DarkGray
        return
    }
    Write-Host ""
    Write-Host ("=" * 64) -ForegroundColor Yellow
    Write-Host "  AI 动过的文件" -ForegroundColor Yellow
    Write-Host ("=" * 64) -ForegroundColor Yellow
    foreach ($x in $new)  { Write-Host "  新写  $x" -ForegroundColor Green }
    foreach ($x in $edit) { Write-Host "  改动  $x" -ForegroundColor Yellow }
    foreach ($x in $gone) { Write-Host "  删除  $x" -ForegroundColor Red }
    if ($snapDir) {
        Write-Host ""
        Write-Host "  改之前的版本在： $snapDir" -ForegroundColor DarkGray
        Write-Host "  想退回去，把那个目录里的文件复制回 workspace\ 覆盖即可。" -ForegroundColor DarkGray
    } else {
        Write-Host ""
        Write-Host "  这次没做备份（-NoSnapshot 或备份目录建不出来），只能看见改动、退不回去。" -ForegroundColor Yellow
    }
    Write-Host ""
}
# ---------------- 6. 拼参数 ----------------
# 参数要拼两次：第一次按原配置，降档重试时按新配置。只留这一份拼装逻辑 ——
# 之前降档那段是手抄一遍的，后来加的开关（多模态、默认系统提示、局域网钥匙）
# 少抄一个就会在重试时悄悄失效，这种漏抄没人看得出来。
function Build-Args {
    $a = @(
        "-m", $model.FullName,
        "--alias", $alias,
        "--host", $lanArg,
        "--port", "$Port",
        "--n-gpu-layers", "$Ngl",
        "--ctx-size", "$Ctx",
        "--threads", "$threads",
        "--jinja",
        "--reasoning-format", "deepseek",
        "--temp",   (Inv $sample.temp),
        "--top-p",  (Inv $sample.top_p),
        "--top-k",  "$([int]$sample.top_k)",
        "--min-p",  (Inv $sample.min_p),
        "--repeat-penalty", (Inv $sample.repeat_penalty),
        "--n-predict", "$([int]$sample.n_predict)"
    )
    # 纯 CPU 跑时没有 CUDA/Vulkan 后端，--flash-attn 和 KV 量化都是显卡侧的东西。
    if ($backend -ne "cpu") {
        $a += @("--flash-attn", "on", "--cache-type-k", $kvType, "--cache-type-v", $kvType)
    }
    if ($LoadMode -ne "auto") {
        $a += @("-lm", $LoadMode)
    }
    if ($mmproj) {
        $a += @("-mm", $mmproj.FullName)
    } else {
        $a += @("--no-mmproj")
    }
    # 默认系统提示：模型自己的模板 + 一个模板变量。JSON 里的引号会在 Windows 拼
    # 命令行时被吃掉（引擎报 "invalid literal; last read: '{d'"），必须转成 \" 再传。
    #
    # 整段还要再用双引号包一层 —— Start-Process 的 -ArgumentList 是「按空格 join」，
    # 不负责给每个参数加引号。提示里只要出现空格（比如"用 write_file 或 edit_file"），
    # 不包引号就会被拆成好几个 argv，引擎收到半截 JSON 然后退出：
    #   error while handling argument "--chat-template-kwargs": [json.exception.parse_error.101]
    #   ... missing closing quote; last read: '"中文回答。……这个系统是'
    # 短提示里全是中文标点、没有空格，所以这个坑一直没露头。
    if ($sysPrompt -and $tplFile) {
        $kw = (@{ default_system = $sysPrompt } | ConvertTo-Json -Compress) -replace '"', '\"'
        $a += @("--chat-template-file", $tplFile, "--chat-template-kwargs", ('"{0}"' -f $kw))
    }
    # 内置工具。名字必须和引擎的清单完全一致，写错一个引擎会直接报错退出。
    if ($toolsOn) {
        # 写模式**故意不给 exec_shell_command**：
        #   实测（shopping-list 那次）模型改文件首选的是 shell，而这里执行的是 Windows cmd —
        #   `echo '- 鸡蛋' >> todo.txt` 把中文写成了乱码 `'- ???? '`，文件当场被它弄坏。
        #   write_file / edit_file 走引擎自己的实现，不受代码页影响；
        #   少给一个「能在这台电脑上跑任意命令」的口子，也就少一档风险。
        $list = if ($AllowWrite) {
            "read_file,file_glob_search,grep_search,get_info,write_file,edit_file"
        } else {
            "read_file,file_glob_search,grep_search,get_info"
        }
        $a += @("--tools", $list)
    }
    return $a
}

$llamaArgs = Build-Args
if ($env:USB_AI_DUMP_ARGS) {
    Write-Host "[DUMP] tplFile=[$tplFile]  sysPrompt.len=$($sysPrompt.Length)  toolsOn=$toolsOn"
    Write-Host "[DUMP] $($llamaArgs -join ' ')"
}
# 引擎默认没设钥匙时会自己打一行警告："no API key is set and CORS allows all origins"。
# 只在本机跑时无所谓；一旦 -Lan 开了局域网，同一个 wifi 下谁都能用 —— 加不加钥匙由人决定。
if ($Lan -and $ApiKey) {
    $llamaArgs += @("--api-key", $ApiKey)
}

Write-Host ""
Write-Host "  上下文   :  $Ctx tokens" -ForegroundColor DarkGray
# 32K 看着大，中文一轮问答就是几百到上千 token，聊二三十轮就满了。
# 满了以后引擎静默丢掉最早的对话 —— 用户的感觉是"它开始记不住刚才说的了"。
# 提前说一句，比让他在第 40 轮自己发现好。
$rounds = [math]::Floor($Ctx / 1100)
if ($rounds -ge 3) {
    Write-Host "              大约能聊 $([math]::Floor($rounds*0.8))~$rounds 轮，之后会开始忘掉最早的对话" -ForegroundColor DarkGray
}
Write-Host "  显存卸载 :  $Ngl 层  (KV 缓存 $kvType)" -ForegroundColor DarkGray
Write-Host "  CPU 线程 :  $threads" -ForegroundColor DarkGray
Write-Host "  端口     :  $Port$(if ($portFrom) { "   （来源：$portFrom）" })" -ForegroundColor DarkGray
Write-Host "  采样     :  temp $(Inv $sample.temp) / top_p $(Inv $sample.top_p) / top_k $([int]$sample.top_k) / min_p $(Inv $sample.min_p)" -ForegroundColor DarkGray
$rp = if ($sample.repeat_penalty -eq 1.0) { "关" } else { Inv $sample.repeat_penalty }
Write-Host "              重复惩罚 $rp ; 单条最长 $(if ([int]$sample.n_predict -eq -1) { '不限' } else { "$([int]$sample.n_predict) token" })" -ForegroundColor DarkGray
if ($LoadMode -ne "auto") {
    Write-Host "  加载方式 :  $LoadMode" -ForegroundColor DarkGray
}
if ($Lan) {
    if ($lanIP) {
        Write-Host "  局域网   :  开   ->   http://${lanIP}:$Port" -ForegroundColor Green
        Write-Host "              手机/平板连同一个 wifi，浏览器打开上面这个地址即可" -ForegroundColor DarkGray
        if (-not $ApiKey) {
            Write-Host "              [注意] 没设钥匙，同一个网络里任何人都能用" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  局域网   :  没找到局域网地址（这台电脑没连路由器）—— 本次只能本机用" -ForegroundColor Yellow
        $Lan = $false
    }
}
if ($tplFile -and $sysPrompt) {
    Write-Host "  系统提示 :  开   (客户端没带 system 时补一句「$sysPrompt」)" -ForegroundColor DarkGray
} elseif ($NoSystemPrompt) {
    Write-Host "  系统提示 :  关   (-NoSystemPrompt)" -ForegroundColor DarkGray
}
if ($toolsOn) {
    $scope = if ($AllowWrite) { "读 + 写（不含执行命令）" } else { "只读" }
    Write-Host "  读文件   :  开   ($scope)   ->   $toolDir" -ForegroundColor Green
    Write-Host "              AI 只能看见这个目录里的东西；把要问的文件放进去" -ForegroundColor DarkGray
    if ($Lan) {
        Write-Host "              [注意] 引擎为了安全，开了读文件就只允许本机网页调用 —— " -ForegroundColor Yellow
        Write-Host "                     同一个 wifi 的手机能聊天，但用不了读文件。" -ForegroundColor Yellow
    }
}
if ($toolNote) {
    Write-Host ""
    Write-Host "  [注意] $toolNote" -ForegroundColor Yellow
}
if ($tplNote) {
    Write-Host ""
    Write-Host "  [注意] $tplNote" -ForegroundColor Yellow
}
if ($vramNote) {
    Write-Host ""
    Write-Host "  [注意] $vramNote" -ForegroundColor Yellow
}
if ($ramNote) {
    Write-Host ""
    Write-Host "  [注意] $ramNote" -ForegroundColor Yellow
}
if ($loadNote) {
    Write-Host ""
    Write-Host "  [注意] $loadNote" -ForegroundColor Yellow
}

# ---------------- 6.9 把"这次到底按什么配置跑的"落成一份人能读的文件 ----------------
# 这些东西以前只在这块黑底窗口里出现过，窗口一关就没了 —— 用户想问"它为什么自动说中文"
# 或者"我上下文设的是多少"，得凭记忆复述。落盘以后随时能用记事本打开看。
# 写成函数是因为降档重试会改 $Ctx/$kvType/$backendName，就绪后要再刷一次，
# 不然文件里写的还是降档前的配置。
$settingsPath = Join-Path $Root "当前设置.txt"
function Write-Settings {
    try {
        $lines = @(
            "U盘 AI 便携版 —— 当前设置",
            "（每次启动自动刷新，可以随时用记事本打开看；改这里没用，改完重启就被覆盖）",
            "",
            "生成时间 :  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
            "启动位置 :  $Root",
            "",
            "模型     :  $($model.Name)   ($([math]::Round($modelGB,2)) GB)",
            "加速方式 :  $backendName",
            "上下文   :  $Ctx tokens",
            "显存卸载 :  $Ngl 层   (KV 缓存 $kvType)",
            "CPU 线程 :  $threads",
            "加载方式 :  $(if ($LoadMode -eq 'auto') { 'auto（按需分页，省内存）' } else { $LoadMode })",
            "端口     :  $Port$(if ($portFrom) { "   （来源：$portFrom）" })",
            "网页界面 :  http://127.0.0.1:$Port"
        )
        $sampleSrc = @()
        foreach ($k in $sampleFrom.Keys) { $sampleSrc += "$k=$($sampleFrom[$k])" }
        $lines += ""
        $lines += "采样参数 :  temp $(Inv $sample.temp) / top_p $(Inv $sample.top_p) / top_k $([int]$sample.top_k) / min_p $(Inv $sample.min_p)"
        $lines += "            重复惩罚 $(Inv $sample.repeat_penalty)   单条最长 $(if ([int]$sample.n_predict -eq -1) { '不限' } else { "$([int]$sample.n_predict) token" })"
        if ($sampleSrc.Count -gt 0) {
            $lines += "            改动来源： $($sampleSrc -join ' ; ')"
        } else {
            $lines += "            全是内置默认值"
        }
        $lines += "            想改：直接编辑 $ParamFile，或命令行加 -Temp / -TopP / -RepeatPenalty 等。"
        $lines += "            可用键： $($ParamDefaults.Keys -join ', ')"
        if ($Lan -and $lanIP) {
            $lines += "局域网   :  开   ->   http://${lanIP}:$Port"
        } else {
            $lines += "局域网   :  关"
        }
        if ($tplFile -and $sysPrompt) {
            $from = if ($SystemPrompt) { "命令行 -SystemPrompt" }
                    elseif ($filePrompt) { "系统提示.txt" }
                    else { "内置默认" }
            $lines += ""
            $lines += "系统提示 :  开   （来源：$from）"
            $lines += "            只在客户端自己没发 system 消息时补上；"
            $lines += "            客户端带了就听客户端的，不会被覆盖、也不会重复注入。"
            $lines += ""
            $lines += "            原文： $sysPrompt"
            $lines += ""
            $lines += "            想改：高级选项.bat 选 [16]；也可以直接编辑 $SysPromptFile 后重启。"
        } elseif ($NoSystemPrompt) {
            $lines += ""
            $lines += "系统提示 :  关   （-NoSystemPrompt，模型按自己的脾气挑语言）"
        } else {
            $lines += ""
            $lines += "系统提示 :  关   （没找到匹配这个模型的模板，见 templates\）"
        }
        if ($toolsOn) {
            $scope = if ($AllowWrite) { "读 + 写（不含执行命令）（-AllowWrite）" } else { "只读" }
            $lines += ""
            $lines += "读文件   :  开   （$scope）"
            $lines += "            AI 只能看见这个目录里的东西： $toolDir"
            $lines += "            只读是默认；想改文件/执行命令要命令行加 -AllowWrite。"
            if ($Lan) { $lines += "            [注意] 开了读文件时，引擎只允许本机网页调用，局域网设备用不了。" }
        }
        if ($retryNote -and $retryNote.Count -gt 0) {
            $lines += ""
            $lines += "启动时自动降过档："
            foreach ($n in $retryNote) { $lines += "  - $n" }
        }
        [IO.File]::WriteAllText($settingsPath, ($lines -join "`n") + "`n", (New-Object Text.UTF8Encoding($true)))
    } catch {
        # 写不进去（写保护的盘）不该拦住启动，静默跳过
    }
}
Write-Settings

# ---------------- 6.6 有没有新版本 ----------------
# 这支 U 盘一旦送出去，作者更新了什么，用的人永远不知道 —— 没有任何别的通道。
# 查一次几十毫秒；没网就静默跳过，绝不因为连不上而拦住启动或者弹窗。
# 只查「最新版 tag 是多少」，不上传任何东西，也不带任何本机信息。
$RepoSlug   = "KAYOYAK/portable-ai-usb"
function Compare-Ver([string]$a, [string]$b) {
    # 返回 1 = a 比 b 新，0 = 一样，-1 = a 旧
    $pa = @($a.TrimStart('v').Split('.') | ForEach-Object { $n = 0; if ([int]::TryParse($_, [ref]$n)) { $n } else { 0 } })
    $pb = @($b.TrimStart('v').Split('.') | ForEach-Object { $n = 0; if ([int]::TryParse($_, [ref]$n)) { $n } else { 0 } })
    for ($i = 0; $i -lt [math]::Max($pa.Count, $pb.Count); $i++) {
        $x = if ($i -lt $pa.Count) { $pa[$i] } else { 0 }
        $y = if ($i -lt $pb.Count) { $pb[$i] } else { 0 }
        if ($x -gt $y) { return 1 }
        if ($x -lt $y) { return -1 }
    }
    return 0
}
function Test-Update([switch]$Quiet) {
    $latest = $null
    try {
        $r = Invoke-RestMethod "https://api.github.com/repos/$RepoSlug/releases/latest" `
             -Headers @{ 'User-Agent' = "portable-ai-usb/$AppVersion" } -TimeoutSec 8 -ErrorAction Stop
        $latest = [string]$r.tag_name
    } catch {
        # 没网、被墙、GitHub 挂了 —— 都是"查不到"，不是错误
        if (-not $Quiet) {
            Write-Host ""
            Write-Host "  查不到（这台机器现在连不上 github.com）。不影响使用。" -ForegroundColor DarkGray
            Write-Host "  想手动看：https://github.com/$RepoSlug/releases" -ForegroundColor DarkGray
        }
        return $null
    }
    if (-not $latest) { return $null }
    $cmp = Compare-Ver $latest $AppVersion
    if ($cmp -le 0) {
        if (-not $Quiet) {
            Write-Host ""
            Write-Host "  已是最新版（$AppVersion）。" -ForegroundColor Green
        }
        return $false
    }
    Write-Host ""
    Write-Host ("=" * 64) -ForegroundColor Cyan
    Write-Host "  有新版本：$latest   （你现在是 $AppVersion）" -ForegroundColor Cyan
    Write-Host ("=" * 64) -ForegroundColor Cyan
    Write-Host "  下载： https://github.com/$RepoSlug/releases/tag/$latest" -ForegroundColor Cyan
    Write-Host "  解压覆盖到 U 盘根目录即可；models\ 和 llama.cpp\ 不用动。" -ForegroundColor DarkGray
    Write-Host ""
    return $true
}

if ($CheckUpdate) {
    Head "检查更新"
    Write-Host "  当前版本 :  $AppVersion"
    Test-Update | Out-Null
    Wait-Enter
    exit 0
}

if ($Probe) {
    Head "探测完成（未启动引擎）"
    Write-Host "  后端 = $backend      模型 = $($model.Name)"
    Write-Host "  ctx  = $Ctx          ngl  = $Ngl         kv = $kvType"
    Write-Host "  内存 = $ramGB GB      显存 = $nvVramGB GB"
    exit 0
}

# ---------------- 6.5 实测这支盘有多快，把"要等多久"说清楚 ----------------
$disk   = Measure-DiskRead -Path $model.FullName
$estSec = Get-EstimateSeconds -Disk $disk -ModelBytes $model.Length
Show-DiskReport -Disk $disk -EstSec $estSec -ModelGB $modelGB

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
        Wait-Enter
        exit 0
    }

    Write-Host "  [提示] 端口 $Port 被别的程序占用了（不是本 U 盘的 AI）。" -ForegroundColor Yellow
    $newPort = 0
    for ($p = $Port + 1; $p -le $Port + 20; $p++) {
        if (-not (Test-PortBusy $p)) { $newPort = $p; break }
    }
    if ($newPort -eq 0) {
        Write-Host "         $Port ~ $($Port + 20) 全被占用，无法启动。请先释放端口。" -ForegroundColor Red
        Wait-Enter; exit 1
    }
    $Port = $newPort
    for ($i = 0; $i -lt $llamaArgs.Count - 1; $i++) {
        if ($llamaArgs[$i] -eq "--port") { $llamaArgs[$i + 1] = "$Port" }
    }
    Write-Host "         已自动改用端口 $Port。" -ForegroundColor Green
}

# 把最终端口落盘。高级选项.bat 的 [8]「打开 AI 网页界面」靠它找地址：
# 端口被占用时启动器会自动换号，菜单那边不可能猜得到。
try {
    [System.IO.File]::WriteAllText((Join-Path $DirLog "端口.txt"), "$Port`r`n", (New-Object System.Text.UTF8Encoding $false))
} catch { }

# ---------------- 8. 启动 ----------------
$url = "http://127.0.0.1:$Port"

# 引擎的日志全部走 stderr，stdout 基本是空的。
# 以前把 stdout 接到 .log、stderr 接到 .log.err，于是打印给用户的那个 .log
# 永远是 0 字节 —— 出问题按提示去翻日志，翻到的是空文件。
# 现在 .log 就是 stderr（真正有内容的那份），stdout 另存 .out 备用。
$log = Join-Path $DirLog ("server-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".log")

# 从引擎日志里认「内存不够」的特征。认得出来才自动降档重试；
# 认不出来就老实报错 —— 不分青红皂白地重试只会把真正的问题盖住。
function Test-OutOfMemory([string]$Text) {
    if (-not $Text) { return $false }
    $pattern = 'out of memory|OutOfMemory|cudaMalloc failed|cudaErrorMemoryAllocation|' +
               'failed to allocate|unable to allocate|CUDA error: out of memory|' +
               'insufficient memory|not enough memory|ggml_backend_.*alloc_buffer.*failed'
    return ($Text -match $pattern)
}

# ---- 一行动态进度 ----
# 秒数来自实测盘速（不是编的常数）；"走到哪一步"来自引擎日志最新一行。
# 引擎在 47 秒的读取过程里一行都不打，所以只靠日志会像卡死 —— 两个合起来才说明问题。
$script:ProgW = 78
try { if ([Console]::WindowWidth -gt 24) { $script:ProgW = [Console]::WindowWidth - 8 } } catch { }
if ($script:ProgW -gt 100) { $script:ProgW = 100 }

function Show-Progress([double]$Elapsed, [double]$Est, [string]$Phase) {
    $barW = 24
    if ($Est -gt 0) {
        $ratio = $Elapsed / $Est
        if ($ratio -gt 1) { $ratio = 1 }
        $full = [int][math]::Round($ratio * $barW)
        $bar  = ("#" * $full) + ("." * ($barW - $full))
        $line = "[$bar] {0,4:N0}s / 约{1:N0}s   {2}" -f $Elapsed, $Est, $Phase
    } else {
        $line = "{0,4:N0}s   {1}" -f $Elapsed, $Phase
    }
    if ($line.Length -gt $script:ProgW) { $line = $line.Substring(0, $script:ProgW) }
    Write-Host ("`r  " + $line.PadRight($script:ProgW)) -NoNewline
}

function Clear-Progress {
    Write-Host ("`r" + (" " * ($script:ProgW + 2)) + "`r") -NoNewline
}

function Start-Engine {
    # 开工具时把引擎的工作目录钉在 $toolDir —— 内置工具读的是相对路径，
    # 引擎的 CWD 就是 AI 能看见的全部世界。模型、模板、日志全走绝对路径，不受影响。
    $wd = if ($toolDir) { $toolDir } else { Split-Path $exe -Parent }
    return (Start-Process -FilePath $exe -ArgumentList $llamaArgs `
            -WorkingDirectory $wd `
            -RedirectStandardOutput ($log + ".out") `
            -RedirectStandardError  $log `
            -PassThru -NoNewWindow)
}

# 返回 "ready" / "died" / "timeout"
function Wait-Engine([System.Diagnostics.Process]$P, [double]$Est) {
    $t0 = Get-Date
    $lastLine = ""
    for ($i = 0; $i -lt 300; $i++) {
        Start-Sleep -Milliseconds 700
        if ($P.HasExited) { return "died" }
        $elapsed = ((Get-Date) - $t0).TotalSeconds

        $phase = "正在把模型读进内存…（这一步最慢，引擎此时不打日志）"
        try {
            $lastLine = Get-Content $log -Tail 1 -ErrorAction SilentlyContinue
        } catch { }
        if ($lastLine) {
            if     ($lastLine -match 'listening on')      { $phase = "引擎已开始监听，正在等它开口…" }
            elseif ($lastLine -match 'model loaded')      { $phase = "模型已就绪，正在起 HTTP 服务…" }
            elseif ($lastLine -match 'threadpool init')   { $phase = "文件读完，正在分配计算缓冲…" }
            elseif ($lastLine -match 'loading model')     { $phase = "正在读模型文件…" }
        }
        Show-Progress -Elapsed $elapsed -Est $Est -Phase $phase

        try {
            $r = Invoke-WebRequest -Uri "$url/health" -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
            if ($r.StatusCode -eq 200) { return "ready" }
        } catch { }
    }
    return "timeout"
}

$ready     = $false
$proc      = $null
$crashed   = $false
$oomTail   = ""
$attempt   = 0
$retryNote = @()
$tplDropped = $false

if ($MaxRetry -lt 0) { $MaxRetry = 0 }

Head "正在启动 AI 引擎"
Write-Host "  加载 $modelGB GB 模型，$(if ($estSec -gt 0) { "实测本盘预计约 $estSec 秒" } else { "约 10~60 秒" })，请勿关闭本窗口" -ForegroundColor Yellow
Write-Host "  日志: $log" -ForegroundColor DarkGray
Write-Host ""

while ($true) {
    $attempt++
    $proc = Start-Engine
    Clear-Progress
    $result = Wait-Engine -P $proc -Est $estSec
    Clear-Progress

    if ($result -eq "ready")  { $ready = $true; break }
    if ($result -eq "timeout") { break }

    # 引擎自己退了。先看是不是内存不够 —— 是的话按档降配重来。
    try { $oomTail = (Get-Content $log -Tail 60 -ErrorAction SilentlyContinue) -join "`n" } catch { $oomTail = "" }
    $isOom = Test-OutOfMemory $oomTail

    # 模板加载失败 → 去掉「默认中文」再来一次。模板是按模型名匹配的，万一匹配上
    # 格式不对的一份，引擎在解析期就直接退出。这时宁可少一个功能，不能让 U 盘起不来。
    # 只试一次：去掉之后还起不来，就是别的原因，交给下面报错。
    #
    # 判据不能宽。早先写的是 'chat template'，可引擎**每次**正常启动都会打
    #   "chat template supports preserving reasoning, it is enabled by default"
    # 于是一旦首启因别的原因失败（比如 -chat-template-kwargs 被空格拆断），
    # 这个修正会误判成"模板坏了"、把好好的默认提示永久摘掉 —— 而且是静默的，
    # 只有启动横幅里多一行"已去掉默认系统提示"。现在只认真正的报错措辞。
    if ($tplFile -and -not $tplDropped -and
        ($oomTail -match '(?i)--chat-template-kwargs|(failed|error|invalid|unsupported|not supported|not valid).{0,40}chat template|chat template.{0,40}(failed|error|invalid|unsupported|not supported|not valid)')) {
        $tplDropped = $true
        $tplFile    = $null
        $sysPrompt  = ""
        $llamaArgs  = Build-Args
        $retryNote += "模板加载失败，已去掉默认系统提示重试（其余配置不变）。"
        Write-Host ""
        Write-Host "  [自动降档] 模型模板加载失败，去掉「默认中文」再试一次……" -ForegroundColor Yellow
        continue
    }

    if (-not $isOom -or $attempt -gt $MaxRetry) { $crashed = $true; break }

    # 降档阶梯：先砍上下文；还不行就退到纯 CPU。
    # 两条路都重新走 Build-Args —— 手抄一份出来，将来加了新开关就会在重试时悄悄少一个。
    Write-Host ""
    if ($attempt -eq 1) {
        $newCtx = [int][math]::Max(8192, [math]::Floor($Ctx / 2))
        if ($Ctx -le 8192) { $newCtx = 8192 }
        $retryNote += "第 1 次重试：显存/内存不够，上下文 $Ctx -> $newCtx，KV 缓存精度降到 q4_0。"
        $Ctx = $newCtx
        $kvType = "q4_0"
        $llamaArgs = Build-Args
        Write-Host "  [自动降档] 显存或内存不够。" -ForegroundColor Yellow
        Write-Host "             上下文 $Ctx，KV 精度 $kvType，先原后端重试……" -ForegroundColor Yellow
    } else {
        $newCtx = [int][math]::Min($Ctx, 8192)
        $retryNote += "第 2 次重试：显存仍不够，改成纯 CPU 跑（上下文 $Ctx，不往显卡塞层）。"
        $Ctx = $newCtx
        $Ngl = 0
        $backend = "cpu"
        $backendName = "CPU"
        $exe = Join-Path (Join-Path $DirLlama "cpu") "llama-server.exe"
        $llamaArgs = Build-Args
        Write-Host "  [自动降档] 还是不够。改用纯 CPU + 上下文 $Ctx 重试……" -ForegroundColor Yellow
    }
    if (-not (Test-Path $exe)) {
        $retryNote += "但没找到 $exe，重试无法进行。"
        $crashed = $true
        break
    }
    Write-Host ""
}

if ($crashed) {
    Write-Host ""
    Write-Host "  [启动失败] 引擎退出了。错误信息：" -ForegroundColor Red
    Write-Host ""
    if (Test-Path $log) { Get-Content $log -Tail 25 }
    Write-Host ""
    if ($retryNote.Count -gt 0) {
        Write-Host "  已经替你试过的自动降档：" -ForegroundColor Yellow
        foreach ($n in $retryNote) { Write-Host "   - $n" -ForegroundColor Yellow }
        Write-Host ""
    }
    Write-Host "  常见原因与对策：" -ForegroundColor Yellow
    Write-Host "   1) 显存不够      -> 双击 高级选项.bat，选 [3] 省显存 / [4] Vulkan / [5] 纯CPU"
    Write-Host "   2) 没装显卡驱动  -> 选 [4] Vulkan 或 [5] 纯CPU"
    Write-Host "   3) 内存太小      -> 选 [5] 纯CPU（mmap 按需分页，比硬塞进显存稳）"
    Write-Host "   4) 杀毒软件拦截  -> 允许 llama-server.exe 运行"
    Write-Host "   5) exe 起不来    -> 见 docs/常见问题.md 的『缺少 DLL』一节"
    Write-Host "   6) 都不是        -> 日志全文：$log" -ForegroundColor DarkGray
    Wait-Enter
    exit 1
}

if ($ready) {
    Write-Host ""
    if ($retryNote.Count -gt 0) {
        Write-Host "  [自动降档] 起是起来了，但降过配置 —— 记一下：" -ForegroundColor Yellow
        foreach ($n in $retryNote) { Write-Host "   - $n" -ForegroundColor Yellow }
        Write-Host ""
    }
    # 降档改过 $Ctx/$kvType/$backendName，刷一次让 当前设置.txt 和实际跑的一致
    Write-Settings
    Write-Host ("=" * 64) -ForegroundColor Green
    Write-Host "   AI 已就绪   ->   $url" -ForegroundColor Green
    Write-Host "   后端: $backendName   上下文: $Ctx   KV: $kvType" -ForegroundColor Green
    Write-Host "   本次设置已写到 当前设置.txt（想知道它为什么自动说中文，翻这个）" -ForegroundColor DarkGray
    if ($Lan -and $lanIP) {
        Write-Host "" 
        Write-Host "   手机/平板同一个 wifi 打开： http://${lanIP}:$Port" -ForegroundColor Green
    }
    Write-Host ("=" * 64) -ForegroundColor Green
    if (-not $NoBrowser) { Start-Process $url }
    # 有新版才吭声，没网/已最新都安静 —— 启动路径上不该多出两行噪音。
    try { Test-Update -Quiet | Out-Null } catch { }
} else {
    if ($proc -and -not $proc.HasExited) {
        Write-Host "  等了 5 分钟还没就绪，但引擎进程还活着、也没报错。" -ForegroundColor Yellow
        Write-Host "  多半是这支盘太慢、或模型偏大。可以直接访问 $url 看看，它可能还在加载。" -ForegroundColor Yellow
        Write-Host "  也可以现在 Ctrl+C 停下，改用 高级选项.bat 的 [3] 省显存 / [5] 纯CPU 再试。" -ForegroundColor Yellow
    } else {
        Write-Host "  等待超时。引擎可能还在加载，可直接访问 $url" -ForegroundColor Yellow
    }
    Write-Host "  日志: $log" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "  保持本窗口开启 = AI 持续运行。关闭窗口或 Ctrl+C 即停止。" -ForegroundColor DarkGray
try { Wait-Process -Id $proc.Id } catch { }
Write-Host "  引擎已停止。"
Show-WorkspaceDiff
