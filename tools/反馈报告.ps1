<#
================================================================
  portable-ai-usb  ·  硬件反馈报告生成器
================================================================
  跑不动的时候，最烦的是「我也不知道要告诉你什么」。
  这个脚本把作者需要的那些信息全收集好，写成一份能直接复制粘贴的报告。

  用法一：双击 U 盘根目录的 高级选项.bat，选 [17]
  用法二：powershell -ExecutionPolicy Bypass -File tools\反馈报告.ps1
          launcher.ps1 起不来的时候用这个 —— 它不依赖引擎能跑起来。

  写两个地方：
    反馈报告.txt          —— 跟着 U 盘走，方便你回头再看
    屏幕上直接打印一遍    —— 方便你复制到 Issue / 聊天窗口
================================================================
#>
[CmdletBinding()]
param(
    [string]$Root = "",     # U 盘根目录。留空 = 从脚本位置往上推
    [switch]$NoFile         # 只打印，不写 反馈报告.txt
)

$ErrorActionPreference = "Continue"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

if (-not $Root) {
    # 脚本在 tools\ 下面，根目录是它上一层
    $Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)
}
if (-not $Root) { $Root = (Get-Location).Path }
$Root = $Root.TrimEnd('\')

# 中文在终端里占两格、ASCII 占一格，用 String.PadRight 会算错（它只数字符数），
# 结果就是带中文的那几行永远对不齐。这里自己数显示宽度。
function Get-Width([string]$s) {
    $w = 0
    foreach ($ch in $s.ToCharArray()) {
        $c = [int]$ch
        if (($c -ge 0x1100 -and $c -le 0x115F) -or
            ($c -ge 0x2E80 -and $c -le 0xA4CF) -or
            ($c -ge 0xAC00 -and $c -le 0xD7A3) -or
            ($c -ge 0xF900 -and $c -le 0xFAFF) -or
            ($c -ge 0xFE30 -and $c -le 0xFE6F) -or
            ($c -ge 0xFF00 -and $c -le 0xFF60) -or
            ($c -ge 0xFFE0 -and $c -le 0xFFE6)) { $w += 2 } else { $w += 1 }
    }
    return $w
}

function Line([string]$k, [string]$v) {
    if ([string]::IsNullOrWhiteSpace($v)) { $v = "(没测出来)" }
    $pad = [Math]::Max(1, 14 - (Get-Width $k))
    return "$k" + (" " * $pad) + ": $v"
}

# ---------------- 1. 硬件 ----------------
$cpu   = ""
$cores = 0
$ramGB = 0
try {
    $cs    = Get-CimInstance Win32_Processor | Select-Object -First 1
    $cpu   = $cs.Name
    $cores = $cs.NumberOfCores
} catch { }
try {
    $ramGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
} catch { }

# 显卡：按显存从大到小，独显排前面（模板里要的是"哪块卡"，核显意义不大）
$gpus = @()
try {
    $gpus = @(Get-CimInstance Win32_VideoController |
              Where-Object { $_.Name } |
              ForEach-Object {
                  $vram = 0
                  try { $vram = [math]::Round($_.AdapterRAM / 1GB, 1) } catch { }
                  [pscustomobject]@{ Name = $_.Name.Trim(); Vram = $vram; Driver = $_.DriverVersion }
              } |
              Sort-Object Vram -Descending)
} catch { }

# 驱动版本：WMI 给的是 32.0.16.1742 这种内部号，用户和作者认的是 617.42 这种市场号。
# 规则：把第 3 段和之后的数字拼起来，取**后五位**，在最后两位前面点一个点。
#   32.0.16.1742  ->  161742  ->  61742  ->  617.42
# 拼起来不够 5 位就不换算，原样给出，免得编一个不存在的号。
function Convert-Driver([string]$dv) {
    if (-not $dv) { return "" }
    $p = $dv.Split('.')
    if ($p.Count -lt 3) { return $dv }
    $digits = ($p[2..($p.Count - 1)] -join '')
    if ($digits.Length -lt 5) { return $dv }
    $five = $digits.Substring($digits.Length - 5)
    return "$($five.Substring(0,3)).$($five.Substring(3))"
}

# ---------------- 2. 软件环境 ----------------
$osVer   = ""
$arch    = ""
try {
    $o = Get-CimInstance Win32_OperatingSystem
    $osVer = "$($o.Caption)  Build $($o.BuildNumber)"
    $arch  = $o.OSArchitecture
} catch { }

# ---------------- 3. 引擎自己怎么看这台机器 ----------------
# 直接问引擎最准：它报的显存是实打实的可用值，WMI 的 AdapterRAM 会溢出（大显存卡显示 4GB）。
$engines = @()
try {
    $engines = @(Get-ChildItem (Join-Path $Root 'llama.cpp') -Directory -ErrorAction SilentlyContinue |
                 ForEach-Object {
                     $exe = Join-Path $_.FullName 'llama-server.exe'
                     if (Test-Path $exe) { [pscustomobject]@{ Name = $_.Name; Exe = $exe } }
                 })
} catch { }

$deviceLines = @()
$usedBackend = ""
foreach ($e in $engines) {
    $out = & $e.Exe --list-devices 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -and $out -match '\S') {
        $deviceLines += "  [$($e.Name)]"
        foreach ($l in ($out -split "`r?`n")) {
            if ($l.Trim()) { $deviceLines += "    " + $l.Trim() }
        }
        if (-not $usedBackend) { $usedBackend = $e.Name }
    }
}

# ---------------- 4. 启动器探测（最接近"实际启动时看到的"） ----------------
$probeText = ""
$probeExe  = Join-Path $Root 'launcher.ps1'
if (Test-Path $probeExe) {
    $probeText = (& powershell -NoProfile -ExecutionPolicy Bypass -File $probeExe -Probe 2>&1 | Out-String)
    if ($probeText) { $probeText = $probeText.Trim() }
}

# ---------------- 5. 组装 ----------------
$gpuMain = if ($gpus.Count -gt 0) { $gpus[0].Name } else { "" }
$gpuAll  = ($gpus | ForEach-Object { $_.Name }) -join '  |  '
$drvRaw  = if ($gpus.Count -gt 0) { $gpus[0].Driver } else { "" }
$drvPub  = Convert-Driver $drvRaw

$out = New-Object System.Collections.Generic.List[string]
$out.Add("===== U盘 AI 便携版 · 硬件反馈报告 =====")
$out.Add("")
$out.Add("【请先填这两行，其余都已自动生成】")
$out.Add("结果        : (能跑 / 起不来 / 能起但很慢)     <- 改这里")
$out.Add("生成速度    : (大概每秒几个字，或「没见到出字」)   <- 改这里")
$out.Add("")
$out.Add("----- 硬件 -----")
$out.Add((Line "CPU"        $(if ($cores) { "$cpu  ($cores 核)" } else { $cpu })))
$out.Add((Line "内存"       $(if ($ramGB) { "$ramGB GB" } else { "" })))
$out.Add((Line "显卡"       $gpuMain))
if ($gpus.Count -gt 1) { $out.Add((Line "显卡(全部)" $gpuAll)) }
$out.Add((Line "显卡驱动"   $(if ($drvPub) { "$drvPub   (内部号 $drvRaw)" } else { "" })))
$out.Add((Line "系统"       $(if ($osVer) { "$osVer   $arch" } else { "" })))
$out.Add("")
$out.Add("----- 引擎看到的设备 -----")
if ($deviceLines.Count -gt 0) { foreach ($l in $deviceLines) { $out.Add($l) } }
else { $out.Add("  (没跑出结果 —— 可能 models\llama.cpp 缺失，或 exe 起不来)") }
$out.Add("")
$out.Add("----- 启动器探测 -----")
if ($probeText) { foreach ($l in ($probeText -split "`r?`n")) { $out.Add("  " + $l) } }
else { $out.Add("  (没跑出结果)") }
$out.Add("")
$out.Add("----- 备注 -----")
$out.Add("(做过哪些操作、报的什么错、屏幕上的原话 —— 贴得越全越好)")
$out.Add("")
$out.Add("")
$out.Add("报告生成时间 : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")

$text = ($out -join "`r`n")

Write-Host ""
Write-Host ("=" * 64)
Write-Host "  硬件反馈报告"
Write-Host ("=" * 64)
Write-Host ""
Write-Host $text
Write-Host ""

if (-not $NoFile) {
    $dst = Join-Path $Root '反馈报告.txt'
    try {
        # BOM + CRLF：这份文件的目标读者是 Windows 记事本和网页表单
        [IO.File]::WriteAllText($dst, $text + "`r`n", (New-Object Text.UTF8Encoding($true)))
        Write-Host ("=" * 64)
        Write-Host "  已保存到 : $dst" -ForegroundColor Green
        Write-Host "  下一步   : 用记事本打开它，把开头「结果」「生成速度」两行填上，" -ForegroundColor Green
        Write-Host "             然后整份复制，发给作者就行。" -ForegroundColor Green
        Write-Host ("=" * 64)
    } catch {
        Write-Host "  [注意] 写不进 $dst —— 这份盘可能是写保护的。" -ForegroundColor Yellow
        Write-Host "         上面已经完整打印过了，直接复制屏幕上的文字也一样。" -ForegroundColor Yellow
    }
    Write-Host ""
}
