<#
================================================================
  portable-ai-usb  ·  高级选项菜单
================================================================
  为什么菜单在 PowerShell 里而不是在 .bat 里：
  cmd.exe 解析批处理时按本地 ANSI 码页逐字节切分，中文
  UTF-8 字节可能撞进 GBK 双字节区间，导致解析器错位、把
  菜单行拆成乱码命令。把中文界面放到 PowerShell 里可以
  彻底绕开这个问题；.bat 只留纯 ASCII 的引导行。
================================================================
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# tools\ 的上一级就是 U 盘根目录
$Here     = $PSScriptRoot
if (-not $Here) { $Here = Split-Path -Parent $MyInvocation.MyCommand.Definition }
$Root     = Split-Path -Parent $Here.TrimEnd('\')
$Launcher = Join-Path $Root 'launcher.ps1'
$SelfTest = Join-Path $Here '自检.ps1'

function Clear-Safe {
    # 非交互场景（无控制台 / stdin 被重定向）下 Clear-Host 会抛异常
    try { Clear-Host } catch { }
}

function Pause-Safe {
    try { Pause } catch { }
}

# 打开 AI 网页界面。端口不一定就是 8080 —— 启动器发现 8080 被别的程序占用时
# 会自动往上换号，换完把结果写进 logs\端口.txt。这里优先读它，读不到才用默认值。
function Open-WebUI {
    $port = 8080
    $f = Join-Path $Root 'logs\端口.txt'
    if (Test-Path $f) {
        $t = Get-Content $f -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        $n = 0
        if ($t -and [int]::TryParse($t.Trim(), [ref]$n) -and $n -gt 0 -and $n -lt 65536) { $port = $n }
    }
    Write-Host ""
    Write-Host "  正在打开 http://127.0.0.1:$port" -ForegroundColor Cyan
    Write-Host "  （如果浏览器显示打不开，说明 AI 还没启动，先回去用 [1] 启动）" -ForegroundColor DarkGray
    Write-Host ""
    try { Start-Process "http://127.0.0.1:$port" } catch { Write-Host "  打不开浏览器：$($_.Exception.Message)" -ForegroundColor Red }
    Pause-Safe
}

# 读一个选择。stdin 被重定向时（管道、计划任务、自动化测试）：
#   PowerShell 5.1 的 Read-Host 会抛 "PowerShell 处于非交互模式"，
#   在 $ErrorActionPreference="Stop" 下直接把整个脚本带走 —— 表现是菜单
#   渲染一次就没了。这里改成显式读一行，读不到才返回 $null。
function Read-Choice([string]$Prompt) {
    try {
        if ([Console]::IsInputRedirected) {
            $line = [Console]::In.ReadLine()
            if ($null -eq $line) { return $null }
            return $line.Trim()
        }
    } catch { return $null }
    try { return (Read-Host $Prompt).Trim() } catch { return $null }
}

function Show-Menu {
    Clear-Safe
    Write-Host ""
    Write-Host "  ============================================================"
    Write-Host "    U盘 AI 便携版  -  高级选项"
    Write-Host "  ============================================================"
    Write-Host ""
    Write-Host "    [1]  NVIDIA  -  32K 上下文   (最常用)"
    Write-Host "    [2]  NVIDIA  -  64K 上下文   (长文档 / 长对话)"
    Write-Host "    [3]  NVIDIA  -   8K 上下文   (小显存机)"
    Write-Host ""
    Write-Host "    [4]  AMD / Intel 显卡  (Vulkan)"
    Write-Host "    [5]  纯 CPU 模式  (任何电脑都能跑, 速度慢)"
    Write-Host ""
    Write-Host "    [6]  仅检测硬件, 不启动"
    Write-Host "    [7]  停止本 U 盘的 AI"
    Write-Host "    [8]  打开 AI 网页界面"
    Write-Host "    [9]  环境自检  (U盘文件是否齐全)"
    Write-Host "    [10] 选择使用哪个模型  (models\ 下有多个时)"
    Write-Host "    [11] 测一下这支 U 盘的速度  (看看要等多久)"
    Write-Host "    [12] 启动  -  不用 mmap  (慢盘卡顿时用, 占内存)"
    Write-Host "    [13] 启动  -  关掉默认说中文  (让模型自己挑语言)"
    Write-Host "    [14] 启动  -  局域网模式  (手机、平板连同一个 wifi 也能用)"
    Write-Host "    [15] 启动  -  让 AI 读文件  (回答「这个文件里写了什么」)"
    Write-Host "    [19] 启动  -  让 AI 改文件  (会自动留备份, 改完列改动)"
    Write-Host ""
    Write-Host "    [16] 设置  (看当前配置 / 改提示 / 改端口 / 调参数)"
    Write-Host "    [17] 生成硬件反馈报告  (跑不动时发给作者)"
    Write-Host "    [18] 模型管理  (看详情 / 换模型 / 删掉不用的)"
    Write-Host "    [20] 检查有没有新版本"
    Write-Host ""
    Write-Host "    [0]  退出"
    Write-Host ""
    Write-Host "  ============================================================"
}

# 注意：这里一律直接写 & $Launcher -Param value，不要包一层
#   function Invoke-Launcher { param([string[]]$ExtraArgs) & $Launcher @ExtraArgs }
# 再用 Invoke-Launcher @('-Bench') 调用。
# 数组 splat 是**按位置**传参，不是按名字：@('-Bench') 会把字符串 "-Bench"
# 当成第一个位置参数的值，绑到 $Backend 上，$Bench 永远是 $False ——
# 表现就是选 [11] 却启动了一个服务器。写死参数名则静态可查、不可能错。

# [10] 换模型：把选择写进 models\当前模型.txt，launcher.ps1 下次读它。
# 写纯文本而不是改脚本，是为了让 U 盘在只读介质、或用户没装编辑器的情况下也能换模型。
function Select-Model {
    Clear-Safe
    $dirModels = Join-Path $Root 'models'
    $pickFile  = Join-Path $dirModels '当前模型.txt'

    Write-Host ""
    Write-Host "  ============================================================"
    Write-Host "    选择使用哪个模型"
    Write-Host "  ============================================================"
    Write-Host ""

    if (-not (Test-Path $dirModels)) {
        Write-Host "  [错误] 找不到 $dirModels" -ForegroundColor Red
        Write-Host ""; Pause-Safe; return
    }

    $models = @(Get-ChildItem $dirModels -Filter '*.gguf' -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notlike 'mmproj-*' } |
                Sort-Object Length -Descending)
    if ($models.Count -eq 0) {
        Write-Host "  [错误] models\ 里没有 .gguf 模型文件" -ForegroundColor Red
        Write-Host ""; Pause-Safe; return
    }

    $current = ''
    if (Test-Path $pickFile) {
        $current = Get-Content $pickFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if ($current) { $current = $current.Trim() }
    }

    for ($i = 0; $i -lt $models.Count; $i++) {
        $mark = ''
        if ($models[$i].Name -eq $current) { $mark = '   <- 当前' }
        Write-Host ("    [{0}]  {1}   ({2:N2} GB){3}" -f ($i + 1), $models[$i].Name, ($models[$i].Length / 1GB), $mark)
    }
    Write-Host ""
    Write-Host "    [a]  自动  (每次用体积最大的那个)"
    Write-Host "    [0]  返回"
    Write-Host ""
    Write-Host "  ============================================================"

    $sel = Read-Choice "   请选择"
    if ($null -eq $sel) { return }

    if ($sel -eq 'a' -or $sel -eq 'A') {
        Remove-Item $pickFile -Force -ErrorAction SilentlyContinue
        Write-Host ""
        Write-Host "  已改为自动：下次启动用 models\ 里体积最大的模型。" -ForegroundColor Green
        Write-Host ""; Pause-Safe; return
    }

    $idx = 0
    if (-not [int]::TryParse($sel, [ref]$idx)) { return }
    if ($idx -lt 1 -or $idx -gt $models.Count) { return }

    $chosen = $models[$idx - 1]
    try {
        [System.IO.File]::WriteAllText($pickFile, $chosen.Name + "`r`n", (New-Object System.Text.UTF8Encoding $false))
    } catch {
        Write-Host "  [错误] 写不进 $pickFile ：$($_.Exception.Message)" -ForegroundColor Red
        Write-Host ""; Pause-Safe; return
    }
    Write-Host ""
    Write-Host "  已选定：$($chosen.Name)" -ForegroundColor Green
    Write-Host "  下次双击 启动AI.bat 就用它。" -ForegroundColor Green
    Write-Host ""; Pause-Safe
}

if (-not (Test-Path $Launcher)) {
    Write-Host ""
    Write-Host "  [错误] 找不到 launcher.ps1，U 盘可能不完整。" -ForegroundColor Red
    Write-Host "         期望位置：$Launcher"
    Write-Host ""
    Pause-Safe
    exit 1
}

while ($true) {
    Show-Menu
    $opt = Read-Choice "   请选择"
    if ($null -eq $opt) { exit 0 }        # stdin 已关闭（非交互运行）时直接退出

    switch ($opt) {
        "1" { & $Launcher -Backend cuda   -Ctx 32768 -Ngl 99 }
        "2" { & $Launcher -Backend cuda   -Ctx 65536 -Ngl 99 }
        "3" { & $Launcher -Backend cuda   -Ctx 8192  -Ngl 99 }
        "4" { & $Launcher -Backend vulkan -Ngl 99 }
        "5" { & $Launcher -Backend cpu    -Ngl 0 -Ctx 8192 }
        "6" {
            & $Launcher -Probe
            Write-Host ""
            Pause-Safe
        }
        "7" {
            Clear-Safe
            & $Launcher -Stop
            Write-Host ""
            Pause-Safe
        }
        "8" { Clear-Safe; Open-WebUI }
        "9" {
            Clear-Safe
            if (Test-Path $SelfTest) { & $SelfTest } else { Write-Host "  [缺失] 找不到 $SelfTest" -ForegroundColor Red }
            Write-Host ""
            Pause-Safe
        }
        "10" { Select-Model }
        "11" {
            Clear-Safe
            # 测速不启动引擎；结果用来告诉人"预计要等多久"
            & $Launcher -Bench
        }
        "12" {
            # 兜底：慢盘上 mmap 按需分页会卡，改成整块读进内存。
            # launcher 自己会检查内存装不装得下，装不下会改回 auto 并说明原因。
            & $Launcher -LoadMode none
        }
        "13" {
            # 关掉「默认说中文」。模型会按自己的脾气挑语言 ——
            # 想要中英混杂、或者想自己用提示词控制语言时用。
            & $Launcher -NoSystemPrompt
        }
        "14" {
            # 局域网：手机、平板连同一个 wifi 就能用。
            # 这里不问要不要钥匙 —— 要走键盘输入的都在 launcher 里，
            # 而这里被 Read-Choice 占着；要钥匙的人在命令行加 -ApiKey。
            Clear-Safe
            Write-Host ""
            Write-Host "  局域网模式：这台电脑会同时监听 127.0.0.1 和局域网地址。" -ForegroundColor Yellow
            Write-Host "  同一个 wifi 下的手机、平板能打开它显示的地址。" -ForegroundColor Yellow
            Write-Host ""
            Write-Host "  [注意] 没设钥匙，同一个网络里任何人都能用。" -ForegroundColor Yellow
            Write-Host "         想加钥匙：高级选项.bat 换成命令行跑" -ForegroundColor DarkGray
            Write-Host "         powershell -ExecutionPolicy Bypass -File launcher.ps1 -Lan -ApiKey 你的钥匙" -ForegroundColor DarkGray
            Write-Host ""
            Pause-Safe
            & $Launcher -Lan
        }
        "15" {
            # 让 AI 能自己读文件。默认只读 —— 把要问的文件丢进 workspace\ 再问。
            # 写文件 / 执行命令那两档只有命令行 -AllowWrite 能开：那是把这台电脑
            # 交出去，不该是菜单里按一个数字就能做的事。
            Clear-Safe
            Write-Host ""
            Write-Host "  让 AI 读文件（只读）：" -ForegroundColor Yellow
            Write-Host "  启动后，把想让 AI 看的文件放进 U 盘上的 workspace 文件夹，"
            Write-Host "  然后直接问「XX 文件里写了什么」—— 它会自己去读，不用你把内容贴进去。"
            Write-Host ""
            Write-Host "  [边界] AI 只能看见 workspace 里的东西，其他地方的文件碰不到。" -ForegroundColor DarkGray
            Write-Host "         只能读，不能改、不能删、不能执行命令。" -ForegroundColor DarkGray
            Write-Host "  [命名] 文件夹名必须保持英文 workspace —— 中文名会让它列不出文件。" -ForegroundColor DarkGray
            Write-Host ""
            Pause-Safe
            & $Launcher -ReadFiles
        }
        "16" {
            # 设置：把「现在到底按什么配置跑」摊开给用户看，并让最常改的两样能改。
            # 做这个是因为 当前设置.txt 只解决了"能看"，用户看完想改还得知道
            # 命令行参数叫什么 —— 那就等于没解决。
            $loop = $true
            while ($loop) {
                Clear-Safe
                $setFile = Join-Path $Root '当前设置.txt'
                $spFile  = Join-Path $Root '系统提示.txt'
                $ptFile  = Join-Path $Root '端口设置.txt'
                $paFile  = Join-Path $Root '参数设置.txt'

                Write-Host ""
                Write-Host "  ============================================================"
                Write-Host "    设置"
                Write-Host "  ============================================================"
                Write-Host ""
                Write-Host "    [1]  看当前设置      (模型 / 上下文 / 系统提示 / 端口 / 采样)"
                Write-Host "    [2]  改默认中文提示   (改掉「它为什么自动说中文」那句话)"
                Write-Host "    [3]  改端口"
                Write-Host "    [6]  调参数          (温度 / 发散度 / 重复惩罚 / 回答长度)"
                Write-Host ""
                Write-Host "    [4]  改回内置的中文提示  (删掉自定义的那句)"
                Write-Host "    [5]  改回默认端口 8080   (删掉自定义的端口)"
                Write-Host "    [7]  全部参数改回默认   (删掉 参数设置.txt)"
                Write-Host ""
                Write-Host "    [0]  返回"
                Write-Host ""

                $sel = Read-Choice "   请选择"
                if ($null -eq $sel) { return }

                switch ($sel) {
                    "1" {
                        Clear-Safe
                        Write-Host ""
                        if (-not (Test-Path $setFile)) {
                            Write-Host "  还没有 当前设置.txt —— 先在 [1] 启动一次，或者现在跑一遍探测。" -ForegroundColor Yellow
                            Write-Host ""
                            Pause-Safe
                            # 探测会顺手把 当前设置.txt 写出来（启动器里 Write-Settings 干的）
                            & $Launcher -Probe | Out-Null
                        }
                        if (Test-Path $setFile) {
                            Write-Host "  ============================================================"
                            Write-Host "    当前设置   ($setFile)"
                            Write-Host "  ============================================================"
                            Write-Host ""
                            Get-Content $setFile -Encoding UTF8 | ForEach-Object { Write-Host "  $_" }
                        } else {
                            Write-Host "  还是没生成 —— 见 常见问题.md" -ForegroundColor Yellow
                        }
                        Write-Host ""
                        Pause-Safe
                    }
                    "2" {
                        Clear-Safe
                        Write-Host ""
                        Write-Host "  改默认中文提示" -ForegroundColor Yellow
                        Write-Host ""
                        Write-Host "  这句只在「客户端自己没发 system 消息」时补上去 ——"
                        Write-Host "  你在网页界面里自己填了系统提示的话，听你的，这句不生效。"
                        Write-Host ""
                        Write-Host "  [经验] 模型对短、直、动词开头的祈使句才有反应。"
                        Write-Host "         「无论用户用什么语言提问，你都只能用简体中文回答」这种长句实测无效。"
                        Write-Host "         内置那句「中文回答。不要出现英文单词。需要读文件就直接调工具。」实测 3/5 中文。"
                        Write-Host ""
                        Write-Host "  [注意] 里面那句「需要读文件就直接调工具」别删。少了它，你越催"
                        Write-Host "         「直接告诉我」，模型越可能不去读文件、直接编一个答案。"
                        Write-Host ""
                        Write-Host "  留空 = 取消自定义，改回内置那句。"
                        Write-Host ""
                        $txt = Read-Choice "  请输入（直接回车取消）"
                        if ($null -eq $txt -or -not $txt.Trim()) { continue }
                        try {
                            [IO.File]::WriteAllText($spFile, $txt.Trim() + "`n", (New-Object Text.UTF8Encoding($true)))
                            Write-Host ""
                            Write-Host "  已保存。下次启动生效：" -ForegroundColor Green
                            Write-Host "    $spFile"
                        } catch {
                            Write-Host ""
                            Write-Host "  写不进去：$($_.Exception.Message)" -ForegroundColor Red
                            Write-Host "  这支盘可能是写保护的。" -ForegroundColor Red
                        }
                        Write-Host ""
                        Pause-Safe
                    }
                    "3" {
                        Clear-Safe
                        Write-Host ""
                        Write-Host "  改端口" -ForegroundColor Yellow
                        Write-Host ""
                        Write-Host "  默认 8080。如果 8080 被别的程序占了，启动器会自己往上找一个空的，"
                        Write-Host "  那种情况不用改这里。只有你**主动想换**（比如同时跑两个）才改。"
                        Write-Host ""
                        Write-Host "  端口范围 1024 ~ 65535。留空 = 取消自定义。"
                        Write-Host ""
                        $txt = Read-Choice "  请输入（直接回车取消）"
                        if ($null -eq $txt -or -not $txt.Trim()) { continue }
                        $n = 0
                        if (-not [int]::TryParse($txt.Trim(), [ref]$n) -or $n -lt 1024 -or $n -gt 65535) {
                            Write-Host ""
                            Write-Host "  [错误] 这不是一个合法端口（要 1024 ~ 65535 之间的整数）" -ForegroundColor Red
                            Write-Host ""
                            Pause-Safe
                            continue
                        }
                        try {
                            [IO.File]::WriteAllText($ptFile, "$n`n", (New-Object Text.UTF8Encoding($true)))
                            Write-Host ""
                            Write-Host "  已保存：端口 = $n，下次启动生效。" -ForegroundColor Green
                        } catch {
                            Write-Host ""
                            Write-Host "  写不进去：$($_.Exception.Message)" -ForegroundColor Red
                        }
                        Write-Host ""
                        Pause-Safe
                    }
                    "4" {
                        Clear-Safe
                        Write-Host ""
                        if (Test-Path $spFile) {
                            Remove-Item $spFile -Force -ErrorAction SilentlyContinue
                            Write-Host "  已删掉 系统提示.txt，改回内置那句：" -ForegroundColor Green
                            Write-Host "    中文回答。不要出现英文单词。需要读文件就直接调工具。"
                        } else {
                            Write-Host "  本来就没设过自定义提示，现在用的就是内置那句。"
                        }
                        Write-Host ""
                        Pause-Safe
                    }
                    "5" {
                        Clear-Safe
                        Write-Host ""
                        if (Test-Path $ptFile) {
                            Remove-Item $ptFile -Force -ErrorAction SilentlyContinue
                            Write-Host "  已删掉 端口设置.txt，改回默认端口 8080。" -ForegroundColor Green
                        } else {
                            Write-Host "  本来就没设过自定义端口，现在用的就是 8080。"
                        }
                        Write-Host ""
                        Pause-Safe
                    }
                    "6" {
                        Clear-Safe
                        Write-Host ""
                        Write-Host "  调参数" -ForegroundColor Yellow
                        Write-Host ""
                        Write-Host "  这些值以前是写死的。改了以后会存进 参数设置.txt，下次启动生效。"
                        Write-Host ""
                        Write-Host "  ------------------------------------------------------------"
                        Write-Host "   键                范围          默认        管什么"
                        Write-Host "  ------------------------------------------------------------"
                        Write-Host "   temp              0 ~ 2         0.6         越低越稳，越高越发散"
                        Write-Host "   top_p             0 ~ 1         0.95        候选词的取舍范围"
                        Write-Host "   top_k             0 ~ 200       20          0 = 关掉"
                        Write-Host "   min_p             0 ~ 1         0           冷水词过滤"
                        Write-Host "   repeat_penalty   0.5 ~ 2       1.1         1.0 = 关掉；老重复就调高"
                        Write-Host "   n_predict         -1 ~ 32768    -1          -1 = 不限；限死能防它啰嗦"
                        Write-Host "  ------------------------------------------------------------"
                        Write-Host ""
                        Write-Host "  一次改一个键：先输键名，再输值。留空 = 不改。"
                        Write-Host ""
                        $key = Read-Choice "  键名（直接回车取消）"
                        if ($null -eq $key -or -not $key.Trim()) { continue }
                        $key = $key.Trim().ToLower()
                        $known = @{
                            temp = @(0.0, 2.0); top_p = @(0.0, 1.0); top_k = @(0, 200)
                            min_p = @(0.0, 1.0); repeat_penalty = @(0.5, 2.0); n_predict = @(-1, 32768)
                        }
                        if (-not $known.ContainsKey($key)) {
                            Write-Host ""
                            Write-Host "  [错误] 不认识这个键：$key" -ForegroundColor Red
                            Write-Host "         可用的：$($known.Keys -join ', ')" -ForegroundColor Red
                            Write-Host ""
                            Pause-Safe
                            continue
                        }
                        $val = Read-Choice "  $key = "
                        if ($null -eq $val -or -not $val.Trim()) { continue }
                        $num = 0.0
                        if (-not [double]::TryParse($val.Trim(), [System.Globalization.NumberStyles]::Float,
                                [System.Globalization.CultureInfo]::InvariantCulture, [ref]$num)) {
                            Write-Host ""
                            Write-Host "  [错误] 这不是数字：$val" -ForegroundColor Red
                            Write-Host ""
                            Pause-Safe
                            continue
                        }
                        $lo = $known[$key][0]; $hi = $known[$key][1]
                        if ($num -lt $lo -or $num -gt $hi) {
                            Write-Host ""
                            Write-Host "  [错误] 超出范围：$key 要在 $lo ~ $hi 之间" -ForegroundColor Red
                            Write-Host ""
                            Pause-Safe
                            continue
                        }
                        # 读旧文件 -> 改这一行（或追加）-> 写回。保留用户自己设过的其它键。
                        $map = [ordered]@{}
                        if (Test-Path $paFile) {
                            foreach ($raw in [IO.File]::ReadAllLines($paFile)) {
                                $m = [regex]::Match($raw.Trim(), '^([A-Za-z_]+)\s*[=:＝：]\s*(.+)$')
                                if ($m.Success) { $map[$m.Groups[1].Value.ToLower()] = $m.Groups[2].Value.Trim() }
                            }
                        }
                        $map[$key] = $val.Trim()
                        $out = @(
                            '# U盘 AI 便携版 —— 采样参数',
                            '# 改完重启生效。删掉某个键 = 该键回到内置默认。',
                            '# 范围：temp 0~2 / top_p 0~1 / top_k 0~200 / min_p 0~1 /',
                            '#       repeat_penalty 0.5~2（1.0=关） / n_predict -1~32768（-1=不限）',
                            ''
                        )
                        foreach ($k in @('temp','top_p','top_k','min_p','repeat_penalty','n_predict')) {
                            if ($map.Contains($k)) { $out += "$k = $($map[$k])" }
                        }
                        try {
                            [IO.File]::WriteAllText($paFile, ($out -join "`n") + "`n", (New-Object Text.UTF8Encoding($true)))
                            Write-Host ""
                            Write-Host "  已保存：$key = $($val.Trim())，下次启动生效。" -ForegroundColor Green
                            Write-Host "    $paFile"
                        } catch {
                            Write-Host ""
                            Write-Host "  写不进去：$($_.Exception.Message)" -ForegroundColor Red
                        }
                        Write-Host ""
                        Pause-Safe
                    }
                    "7" {
                        Clear-Safe
                        Write-Host ""
                        if (Test-Path $paFile) {
                            Remove-Item $paFile -Force -ErrorAction SilentlyContinue
                            Write-Host "  已删掉 参数设置.txt，所有采样参数改回内置默认：" -ForegroundColor Green
                            Write-Host "    temp 0.6 / top_p 0.95 / top_k 20 / min_p 0 / repeat_penalty 1.1 / n_predict 不限"
                        } else {
                            Write-Host "  本来就没改过参数，现在用的就是内置默认值。"
                        }
                        Write-Host ""
                        Pause-Safe
                    }
                    "0" { $loop = $false }
                    default { }
                }
            }
        }
        "17" {
            # 硬件反馈报告：跑不动时最烦「不知道该告诉对方什么」。
            # 独立脚本，不依赖引擎能起来 —— launcher 起不来的时候正是最需要它的时候。
            Clear-Safe
            $rep = Join-Path $Root 'tools\反馈报告.ps1'
            if (-not (Test-Path $rep)) {
                Write-Host ""
                Write-Host "  [错误] 找不到 $rep" -ForegroundColor Red
                Write-Host "         这支盘的 tools\ 目录不完整，先跑一次 [9] 环境自检。" -ForegroundColor Red
                Write-Host ""
                Pause-Safe
                continue
            }
            & powershell -NoProfile -ExecutionPolicy Bypass -File $rep -Root $Root
            Pause-Safe
        }
        "18" {
            # 模型管理：models\ 里放了多个模型时，看得清、换得动、删得掉。
            $loop = $true
            while ($loop) {
                Clear-Safe
                $dirModels = Join-Path $Root 'models'
                $pickFile  = Join-Path $dirModels '当前模型.txt'

                Write-Host ""
                Write-Host "  ============================================================"
                Write-Host "    模型管理"
                Write-Host "  ============================================================"
                Write-Host ""

                if (-not (Test-Path $dirModels)) {
                    Write-Host "  [错误] 找不到 $dirModels" -ForegroundColor Red
                    Write-Host ""
                    Pause-Safe
                    break
                }

                $models = @(Get-ChildItem $dirModels -Filter '*.gguf' -File -ErrorAction SilentlyContinue |
                            Where-Object { $_.Name -notlike 'mmproj-*' } |
                            Sort-Object Length -Descending)
                $projs  = @(Get-ChildItem $dirModels -Filter 'mmproj-*.gguf' -File -ErrorAction SilentlyContinue)

                if ($models.Count -eq 0) {
                    Write-Host "  [错误] models\ 里没有 .gguf 模型文件" -ForegroundColor Red
                    Write-Host ""
                    Pause-Safe
                    break
                }

                $current = ''
                if (Test-Path $pickFile) {
                    $current = (Get-Content $pickFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue)
                    if ($current) { $current = $current.Trim() }
                }

                # 量化档位能从文件名里读出来（Q5_K_M / Q4_K_M / IQ4_XS …）。
                # 它是挑模型时最有用的一个数 —— 直接决定吃多少显存、掉多少智商。
                Write-Host ("    {0,-3} {1,-46} {2,8}  {3}" -f '#', '文件名', '大小', '量化')
                Write-Host ("    " + ("-" * 74))
                for ($i = 0; $i -lt $models.Count; $i++) {
                    $m = $models[$i]
                    $q = ''
                    # 未量化的那几种也常见（F16/BF16 是原始精度），一并认出来 ——
                    # 对用户来说「这是没压缩的原版、会特别大」和「这是 Q4 压过的」一样重要。
                    $qm = [regex]::Match($m.Name, '(?i)\b(I?Q\d(?:_[A-Z0-9]+)*|BF16|F16|F32)\b')
                    if ($qm.Success) { $q = $qm.Groups[1].Value.ToUpper() }
                    if (-not $q) { $q = '(看不出)' }
                    $mark = ''
                    if ($m.Name -eq $current) { $mark = '  <- 当前' }
                    elseif (-not $current -and $i -eq 0) { $mark = '  <- 当前(自动:最大的)' }
                    Write-Host ("    [{0,-1}] {1,-46} {2,7:N2}G  {3}{4}" -f ($i + 1), $m.Name, ($m.Length / 1GB), $q, $mark)
                }
                if ($projs.Count -gt 0) {
                    Write-Host ""
                    Write-Host "    附带的视觉模块（让模型能看图，不单独选）：" -ForegroundColor DarkGray
                    foreach ($p in $projs) { Write-Host ("      {0}   ({1:N2} GB)" -f $p.Name, ($p.Length / 1GB)) -ForegroundColor DarkGray }
                }

                Write-Host ""
                Write-Host "    [s]  换模型        (和 [10] 一样，写进 models\当前模型.txt)"
                Write-Host "    [d]  删掉某个模型   (腾空间用；不可恢复)"
                Write-Host "    [0]  返回"
                Write-Host ""

                $sel = Read-Choice "   请选择"
                if ($null -eq $sel) { return }

                switch ($sel) {
                    "s" { Select-Model; continue }
                    "d" {
                        Clear-Safe
                        Write-Host ""
                        Write-Host "  删掉哪个？输入上面的编号（0 = 取消）" -ForegroundColor Yellow
                        Write-Host ""
                        $p = Read-Choice "  编号"
                        if ($null -eq $p) { return }
                        $pi = 0
                        if (-not [int]::TryParse($p, [ref]$pi) -or $pi -lt 1 -or $pi -gt $models.Count) {
                            if ($p -ne "0" -and $p.Trim()) {
                                Write-Host ""
                                Write-Host "  [错误] 没有这个编号" -ForegroundColor Red
                                Write-Host ""
                                Pause-Safe
                            }
                            continue
                        }
                        $m = $models[$pi - 1]
                        Write-Host ""
                        Write-Host "  要删的是：" -ForegroundColor Yellow
                        Write-Host "    $($m.Name)   ($([math]::Round($m.Length / 1GB, 2)) GB)"
                        Write-Host ""
                        Write-Host "  [注意] 删了就没了，得重新下载。" -ForegroundColor Yellow
                        Write-Host "         如果它正在被用（AI 开着），删会失败 —— 先用 [7] 停掉。" -ForegroundColor Yellow
                        Write-Host ""
                        $ok = Read-Choice "  确认删除请输入 YES"
                        if ($ok -ne 'YES') {
                            Write-Host ""
                            Write-Host "  已取消，什么都没删。"
                            Write-Host ""
                            Pause-Safe
                            continue
                        }
                        try {
                            Remove-Item $m.FullName -Force -ErrorAction Stop
                            # 删掉的正好是"当前"的话，清掉指针免得启动时找不到模型
                            if ($m.Name -eq $current) {
                                Remove-Item $pickFile -Force -ErrorAction SilentlyContinue
                                Write-Host ""
                                Write-Host "  它原本是「当前」模型，已把 当前模型.txt 清掉 —— 下次启动自动挑最大的。" -ForegroundColor Yellow
                            }
                            Write-Host ""
                            Write-Host "  已删除：$($m.Name)" -ForegroundColor Green
                        } catch {
                            Write-Host ""
                            Write-Host "  删不掉：$($_.Exception.Message)" -ForegroundColor Red
                            Write-Host "  （多半是 AI 还开着占住了文件 —— 先用 [7] 停掉）" -ForegroundColor Red
                        }
                        Write-Host ""
                        Pause-Safe
                    }
                    "0" { $loop = $false }
                    default { }
                }
            }
        }
        "19" {
            # 让 AI 改文件。默认关闭 —— 这一档模型能写、能改、能执行命令，
            # 等于把这台电脑交出去。菜单里给，但每次都要先看清这几行。
            Clear-Safe
            Write-Host ""
            Write-Host "  让 AI 改文件（可写）：" -ForegroundColor Yellow
            Write-Host ""
            Write-Host "  这一档会多开三个能力：" -ForegroundColor Yellow
            Write-Host "    写新文件 / 修改已有文件 / 执行命令"
            Write-Host ""
            Write-Host "  [边界] 只能动 workspace 里的东西。" -ForegroundColor DarkGray
            Write-Host "  [备份] 每次启动前会把 workspace 原样备份一份，改完列出哪些被改。" -ForegroundColor DarkGray
            Write-Host "  [注意] 能执行命令 = 它能在你电脑上跑程序。别让它读你不信的文件后乱操作。" -ForegroundColor Yellow
            Write-Host ""
            $ok = Read-Choice "  想清楚再继续。输入 YES 开启，直接回车取消"
            if ($ok -ne 'YES') {
                Write-Host ""
                Write-Host "  已取消。"
                Write-Host ""
                Pause-Safe
                continue
            }
            & $Launcher -AllowWrite
        }
        "20" {
            # 检查更新：不是自动更新，只告诉用户"有新的了，去哪下"。
            Clear-Safe
            & $Launcher -CheckUpdate
            Pause-Safe
        }
        "0" { exit 0 }
        "q" { exit 0 }
        default { }
    }

    # 选项 1-5 会进入 launcher 的等待循环，正常不会回到这里
}
