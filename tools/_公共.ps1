# ====================================================================
#  portable-ai-usb  ·  _公共.ps1
# ====================================================================
#  准备U盘.ps1 和 换模型.ps1 共用的一组函数。
#
#  这个文件不是拿来直接跑的，它是被「点源」进来的：
#      . (Join-Path $PSScriptRoot "_公共.ps1")
#
#  为什么要有这个文件：下载这件事（断点续传、多镜像回退、大小与哈希校验）
#  只有一套实现。抄成两份的话，下面 Get-File 里那条镜像的坑早晚会只修好一份。
# ====================================================================

$Root  = Split-Path -Parent $PSScriptRoot          # 仓库根目录
$Stash = Join-Path $env:TEMP "portable-ai-usb"     # 本机暂存（下载到这儿再拷过去）
if (-not (Test-Path $Stash)) { New-Item -ItemType Directory -Force -Path $Stash | Out-Null }

function Head($t) {
    Write-Host ""
    Write-Host ("=" * 68) -ForegroundColor DarkCyan
    Write-Host ("  " + $t) -ForegroundColor Cyan
    Write-Host ("=" * 68) -ForegroundColor DarkCyan
}
function Step($n, $t) { Write-Host ""; Write-Host "  [$n] $t" -ForegroundColor Yellow }
function OK($t)   { Write-Host "      [OK]   $t" -ForegroundColor Green }
function Info($t) { Write-Host "      · $t" -ForegroundColor DarkGray }
function Warn($t) { Write-Host "      [注意] $t" -ForegroundColor Yellow }
function Die($t)  { Write-Host ""; Write-Host "  [错误] $t" -ForegroundColor Red; exit 1 }

# 非交互环境下 Read-Host 会直接抛异常（stdin 被重定向时），
# 所以先问一句「现在能不能问」。判断不了就当不能问，走默认值。
function Test-CanAsk {
    try { return -not [Console]::IsInputRedirected } catch { return $false }
}

function Wait-Enter([string]$Msg = "      回车继续") {
    if (-not (Test-CanAsk)) { return }
    try { Read-Host $Msg } catch { }
}

function Ask-Yes($q, $defYes = $true) {
    if ($Yes) { return $true }
    if (-not (Test-CanAsk)) { return $defYes }
    $s = if ($defYes) { "[Y/n]" } else { "[y/N]" }
    $a = Read-Host "      $q $s"
    if ([string]::IsNullOrWhiteSpace($a)) { return $defYes }
    return ($a -match '^(?i)y')
}

# 断点续传下载。curl 的 -C - 会自动接上已有部分重新请求。
#
# 坑（踩过）：某些镜像（如 gh-proxy.com）收到 Range 请求时会挂住不返回，所以必须带
#   --max-time 30，每轮只跑 30 秒，靠外层 while 循环累积进度。
#   更阴的是：另一些镜像会无视 Range、把整个文件从头返回。这时文件长度照样增长，
#   但内容是错的 —— 所以大小对了不算数，最后必须靠 SHA-256 兜底（见 Test-Sha256）。
function Get-File {
    param([string]$Url, [string]$Dest, [long]$Expected = 0)

    $destDir = Split-Path -Parent $Dest
    if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }

    if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
        Warn "找不到 curl.exe（Windows 10 1803 以上自带）。换一台机器，或手动把文件放好。"
        return $false
    }

    # 没给期望大小就问服务器要一个。
    #
    # 这一步不是"顺手校验"：下面那个 while 循环完全靠 $Expected 判断"下完了没有"。
    # 缺了它，一次**成功**的下载会在文件不再增长之后被判成"连续无进展"，
    # 撑满 8 轮之后返回 false —— 调用方于是把已经下好的文件当成失败。
    # （踩过：准备U盘.ps1 下模型时没传 -Expected，干净机器上必然误报"模型下载失败"。）
    if ($Expected -le 0) { $Expected = Get-RemoteSize $Url }

    if ($Expected -gt 0 -and (Test-Path $Dest) -and (Get-Item $Dest).Length -eq $Expected) {
        OK "已存在，跳过：$(Split-Path -Leaf $Dest)"
        return $true
    }

    # 服务器连大小都不给（分块传输等）：没有大小就没法安全续传，也没法判断是否下完。
    # 这种情况只跑一次普通下载，用 curl 自己的退出码判定成败。
    if ($Expected -le 0) {
        Write-Host "      下载中 ...（服务器未提供大小）" -NoNewline
        & curl.exe -sS --ssl-no-revoke -L --max-time 1800 -o $Dest $Url 2>$null
        $code = $LASTEXITCODE
        Write-Host ""
        $got = if (Test-Path $Dest) { (Get-Item $Dest).Length } else { 0 }
        if ($code -eq 0 -and $got -gt 0) {
            OK "$(Split-Path -Leaf $Dest)  ($([math]::Round($got / 1MB, 1)) MB)"
            return $true
        }
        Warn "下载失败：$(Split-Path -Leaf $Dest)（curl 退出码 $code，只收到 $got 字节）"
        return $false
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

# 问一下服务器「这个文件多大」，用来在下之前先对一遍账。
#
# 为什么需要它（踩过）：脚本里写死的大小是会过期的 —— 上游重新上传一次资产，
# 数字就变了，而「大小不对」要等整个文件下完才报出来，白等一场。
# 这个检查一秒就返回。取不到就返回 0，让调用方照旧下载：
# 不要因为一次 HEAD 失败就把人拦在门外。
function Get-RemoteSize($Url) {
    try {
        $h = & curl.exe -sIL --ssl-no-revoke --max-time 20 $Url 2>$null
        $m = ($h | Select-String -Pattern '^content-length:\s*(\d+)').Matches | Select-Object -Last 1
        if ($m) { return [long]$m.Groups[1].Value }
    } catch { }
    return 0
}

# 往 models\校验.txt 里写一条记录，其余行原样保留（同名的替换）。
#
# 为什么需要：下载时验过一次哈希，但那个值只活在这次运行里。清单是 tools\自检.ps1
# 唯一的基准 —— 不写回去，用户换完模型跑自检就只会看到「清单是旧的，重跑
# tools\准备U盘.ps1 可以补上」，等于为了补一行记录让人去跑组装整支 U 盘的脚本。
function Update-ModelManifest($ModelsDir, [string]$Name, [string]$Hash, [long]$Size) {
    $manifest = Join-Path $ModelsDir "校验.txt"
    $keep = [ordered]@{}
    if (Test-Path -LiteralPath $manifest) {
        foreach ($ln in @(Get-Content -LiteralPath $manifest -Encoding UTF8 -ErrorAction SilentlyContinue)) {
            # 格式：<64位十六进制>  <字节数>  <文件名>
            if ($ln -match '^\s*([0-9a-fA-F]{64})\s+(\d+)\s+(.+?)\s*$') {
                $nm = $Matches[3]
                if ($nm -ne $Name) {
                    $keep[$nm] = ("{0}  {1}  {2}" -f $Matches[1].ToLower(), [long]$Matches[2], $nm)
                }
            }
        }
    }
    $keep[$Name] = ("{0}  {1}  {2}" -f $Hash.ToLower(), $Size, $Name)
    $out = @("# 模型校验清单 —— 由 tools\准备U盘.ps1 / tools\换模型.ps1 生成，tools\自检.ps1 用它复查文件有没有坏。",
             "# 格式：<sha256>  <字节数>  <文件名>",
             "")
    foreach ($nm in ($keep.Keys | Sort-Object)) { $out += $keep[$nm] }
    try {
        [IO.File]::WriteAllText($manifest, ($out -join "`r`n") + "`r`n", (New-Object Text.UTF8Encoding($true)))
        return $true
    } catch {
        # 写不进去不致命（U 盘只读、权限不足），但要说出来 —— 否则用户下次自检
        # 看到「清单是旧的」会以为是自己操作错了。
        Warn "校验清单写不进去（$($_.Exception.Message)）。下次自检会提示清单是旧的。"
        return $false
    }
}
