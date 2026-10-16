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
    [string]$LoadMode = "auto"     # 模型加载方式。默认 auto（=mmap，按需分页）。
                                   # 慢盘上 mmap 抖动导致卡顿时，用 none 整块读进内存。
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

    $r = [ordered]@{ SeqMBps = 0.0; RandIOPS = 0; RandMBps = 0.0; Samples = @(); Error = $null; Raw = $true }
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
            for ($i = 0; $i -lt 128; $i++) {
                $pos = $base + [long](($rnd2.NextDouble() * $span) / 4096) * 4096
                if ([PsRawDisk]::Seek($h, $pos) -lt 0) { break }
                if ([PsRawDisk]::Read($h, $bufBlk, 4096) -lt 0) { $miss++ }
            }
            $sw2.Stop()
            $sec = $sw2.Elapsed.TotalSeconds
            if ($sec -gt 0 -and $miss -eq 0) {
                $r.RandIOPS = [math]::Round(128 / $sec, 0)
                $r.RandMBps = [math]::Round((128 * 4KB / 1MB) / $sec, 2)
            }
        }
    } catch {
        $r.Error = $_.Exception.Message
        $r.SeqMBps = 0.0
    } finally {
        if ($h) { $h.Dispose() }
        [PsRawDisk]::Free($rawSeq)
        [PsRawDisk]::Free($rawBlk)
    }
    return $r
}

# 为什么还留着一份带缓冲的实现：
#   FILE_FLAG_NO_BUFFERING 在少数环境下会直接失败（盘被独占、部分虚拟盘 / 网络盘、
#   非 4096 扇区）。那种时候退回带缓冲读，至少还能测个数 —— 只是可能吃到系统缓存，
#   所以结果上打 Raw=$false，让 Show-DiskReport 去判断和提示。
function Measure-DiskReadBuffered {
    param([string]$Path)

    $r = [ordered]@{ SeqMBps = 0.0; RandIOPS = 0; RandMBps = 0.0; Samples = @(); Error = $null; Raw = $false }
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
            for ($i = 0; $i -lt 128; $i++) {
                $fs.Position = $base + [long]($rnd.NextDouble() * $span)
                [void]$fs.Read($blk, 0, $blk.Length)
            }
            $sw2.Stop()
            $sec = $sw2.Elapsed.TotalSeconds
            if ($sec -gt 0) {
                $r.RandIOPS = [math]::Round(128 / $sec, 0)
                $r.RandMBps = [math]::Round((128 * 4KB / 1MB) / $sec, 2)
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
    Write-Host "  读 2×32 MB 顺序 + 128 次随机 4K，几秒钟"
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
if ($LoadMode -ne "auto") {
    $llamaArgs += @("-lm", $LoadMode)
}
if ($mmproj) {
    $llamaArgs += @("-mm", $mmproj.FullName)
} else {
    $llamaArgs += @("--no-mmproj")
}

Write-Host ""
Write-Host "  上下文   :  $Ctx tokens" -ForegroundColor DarkGray
Write-Host "  显存卸载 :  $Ngl 层  (KV 缓存 $kvType)" -ForegroundColor DarkGray
Write-Host "  CPU 线程 :  $threads" -ForegroundColor DarkGray
if ($LoadMode -ne "auto") {
    Write-Host "  加载方式 :  $LoadMode" -ForegroundColor DarkGray
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

# ---------------- 8. 启动 ----------------
$log = Join-Path $DirLog ("server-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".log")
$url = "http://127.0.0.1:$Port"

Head "正在启动 AI 引擎"
Write-Host "  加载 $modelGB GB 模型，$(if ($estSec -gt 0) { "实测本盘预计约 $estSec 秒" } else { "约 10~60 秒" })，请勿关闭本窗口" -ForegroundColor Yellow
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
    Wait-Enter
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
