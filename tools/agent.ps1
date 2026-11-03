# ====================================================================
#  portable-ai-usb  ·  AI编程.ps1
# ====================================================================
#  用 MiMo Code 驱动这支 U 盘上的本地模型写代码。
#
#  为什么 MiMo Code 能进这支盘而不用装 Node：
#    它的 npm 包只是个 20 KB 的包装器，真正的程序是 Bun 编译的独立 exe
#    （mimo.exe，约 130 MB），从 author 的 FDS 下载，不需要任何运行时。
#    所以整支盘依然是「插上就能用」，不需要用户装 Node / npm。
#
#  为什么要把配置和数据指回 U 盘：
#    MiMo Code 默认把配置写到 ~/.config/mimocode、数据写到用户目录。
#    那样的话换一台电脑插上，配置、会话、凭据全都没了 —— 就不算便携。
#    它遵循 XDG 约定，四个 XDG_* 环境变量一设，全部落在盘上。
# ====================================================================
[CmdletBinding()]
param(
    # 其余参数原样透传给 mimo.exe（比如 run / models / --help）
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$MimoArgs
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$Root   = Split-Path -Parent $PSScriptRoot
$Agent  = Join-Path $Root "agent"
$Port   = 8080

# 二进制按平台分目录放（agent\windows-x64\mimo.exe 等），这里挑当前机器对应的那份。
# 这个脚本本身只会被 Windows 的 AI编程.bat 调用，所以只看 Windows 两档；
# macOS / Linux 走的是各自平台那份脚本。
$Arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "x64" }
$PlatId = "windows-$Arch"
$Exe    = Join-Path $Agent (Join-Path $PlatId "mimo.exe")

function Say([string]$t, [string]$c = "Gray") { Write-Host "  $t" -ForegroundColor $c }

Write-Host ""
Write-Host "  ============================================================" -ForegroundColor DarkCyan
Write-Host "    AI 编程  ·  MiMo Code + 本地模型" -ForegroundColor White
Write-Host "  ============================================================" -ForegroundColor DarkCyan

# ---------------- 1. 有没有装 ----------------
if (-not (Test-Path $Exe)) {
    Write-Host ""
    Say "[错误] 找不到 agent\$PlatId\mimo.exe" "Red"
    Say "       这一项是单独下载的（每个平台约 100~130 MB），不在 Git 仓库里。" "Gray"
    Say "       装法：跑一次 tools\准备U盘.ps1，会把六个平台一次补齐。" "Gray"
    $have = @()
    if (Test-Path $Agent) {
        $have = @(Get-ChildItem $Agent -Directory -ErrorAction SilentlyContinue |
                  Where-Object { Test-Path (Join-Path $_.FullName "mimo.exe") } |
                  ForEach-Object { $_.Name })
    }
    if ($have.Count -gt 0) { Say "       盘上现有这些平台：$($have -join ', ')" "Gray" }
    exit 1
}

# ---------------- 2. 主模型在不在跑 ----------------
# 判断标准不是「8080 有没有人监听」，而是「监听的那个是不是本盘的模型」——
# 别人机器上的 llama-server 也可能占着 8080，那样连上去就会用错模型。
function Get-OurServer {
    try {
        $r = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/props" -TimeoutSec 3 -ErrorAction Stop
        if (-not $r.model_path) { return $null }
        # 比到「目录边界」为止。只比前缀的话，Root=D:\myusb 会匹配上
        # D:\myusbx\models\x.gguf —— 那是另一个地方的模型，连上去就用错了。
        $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
        $modelFull = [IO.Path]::GetFullPath([string]$r.model_path)
        if ($modelFull.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) { return $r }
    } catch { }
    return $null
}

$props = Get-OurServer
if (-not $props) {
    Write-Host ""
    Say "[需要先启动模型]" "Yellow"
    Say "AI 编程要连本地模型，但它现在没在跑（或者 8080 上是别人的服务）。" "Gray"
    Write-Host ""
    Say "请先双击 U 盘根目录的「启动AI.bat」等它起来，再重新打开这个窗口。" "White"
    Say "（想让 AI 能读写文件，启动时选菜单 [19]；只读用 [15]。）" "DarkGray"
    Write-Host ""
    Say "如果你刚才已经开着一个，可能是端口被改了 —— 看一下 logs\端口.txt。" "DarkGray"
    exit 1
}

$ctx = 0
try { $ctx = [int]$props.default_generation_settings.n_ctx } catch { }
if ($ctx -le 0) { $ctx = 32768 }

Say "模型     :  $(Split-Path $props.model_path -Leaf)" "Green"
Say "上下文   :  $ctx tokens" "Green"
Say "服务     :  http://127.0.0.1:$Port" "DarkGray"

# 上下文不够就直接警告。实测：32K 下 MiMo Code 的系统提示 + 工具定义本身就吃掉
# 大半，跑到第三轮必定 `Context size has been exceeded`，而用户不知道是自己
# 启动时选错了档 —— 他只会觉得「这功能坏了」。
# 不拦死，因为简单任务（读一个文件、改一行）有时能撑住；但必须说清楚。
if ($ctx -lt 65536) {
    Write-Host ""
    Say "============================================================" "Yellow"
    Say "[注意] 上下文只有 $ctx，AI 编程很可能跑不完一轮工具调用。" "Yellow"
    Say "" "Yellow"
    Say "       它每轮都要带上系统提示和工具定义，32K 兜不住。实测在这种" "Gray"
    Say "       配置下跑两三轮就会报 Context size has been exceeded。" "Gray"
    Write-Host ""
    Say "       想正常用：关掉这个窗口，用 启动AI.bat 的菜单 [2]" "White"
    Say "       （64K 上下文）重新启动模型，再打开 AI编程.bat。" "White"
    Say "       显存代价很小：32K→64K 只多约 170 MB。" "DarkGray"
    Say "============================================================" "Yellow"
    Write-Host ""
}

# ---------------- 3. 配置落回 U 盘 ----------------
# 四个 XDG 变量全部指到 agent\ 下面。MiMo Code 会在这里放：
#   config\mimocode\mimocode.jsonc   配置
#   data\mimocode\                   数据库、会话、日志
#   cache\  state\                   缓存和状态
$cfgHome = Join-Path $Agent "config"
$dataHome = Join-Path $Agent "data"
$cacheHome = Join-Path $Agent "cache"
$stateHome = Join-Path $Agent "state"
foreach ($d in @($cfgHome, $dataHome, $cacheHome, $stateHome)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# 注册本地 provider。limit 必须同时给 context 和 output —— 这是 schema 的要求。
# 不给 limit 的话它会以为模型有 1M 上下文，然后按那个去塞，请求会直接超限。
$cfgDir = Join-Path $cfgHome "mimocode"
if (-not (Test-Path $cfgDir)) { New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null }
$cfgPath = Join-Path $cfgDir "mimocode.jsonc"

$bodyCtx = 4096
$cfgText = @"
{
  "`$schema": "https://mimo.xiaomi.com/mimocode/config.json",
  "model": "local/mimo-9b",
  "provider": {
    "local": {
      "name": "本机（U 盘）",
      "npm": "@ai-sdk/openai-compatible",
      "only_configured_models": true,
      "models": {
        "mimo-9b": {
          "name": "MiMo-V2.6-Distill-Qwen-9B",
          "tool_call": true,
          "limit": { "context": $ctx, "output": $bodyCtx }
        }
      },
      "options": {
        "baseURL": "http://127.0.0.1:$Port/v1",
        "apiKey": "none"
      }
    }
  }
}
"@

# 每次启动都重写：上下文可能因为菜单 [2]/[3] 而变，硬编码一份旧的会误导模型。
try {
    [IO.File]::WriteAllText($cfgPath, $cfgText, (New-Object Text.UTF8Encoding($false)))
} catch {
    Say "[注意] 配置写不进去（$($_.Exception.Message)）—— 可能盘满了或只读" "Yellow"
}

$env:XDG_CONFIG_HOME = $cfgHome
$env:XDG_DATA_HOME   = $dataHome
$env:XDG_CACHE_HOME  = $cacheHome
$env:XDG_STATE_HOME  = $stateHome

# ---------------- 4. 交给 mimo.exe ----------------
Write-Host ""
Say "第一次用会问选模型，选 local/mimo-9b 就行。" "DarkGray"
Say "退出：在界面里按 Esc，或者 Ctrl+C。" "DarkGray"
Write-Host ""

& $Exe @MimoArgs
$code = $LASTEXITCODE

# TUI 退出后终端可能还停在备用屏/隐藏光标状态，恢复一下，
# 否则用户看到的是一个没有光标、翻不动旧输出的窗口。
# 用 [char]27 而不是 "`e" —— 这个脚本是被 powershell(5.1) 调起来的，
# 5.1 不认识 `e 转义，会原样打印出 "e[?25h" 这串字符。
try {
    $esc = [char]27
    [Console]::Write("$esc[?25h$esc[?1049l")
    [Console]::Out.Flush()
} catch { }

exit $code
