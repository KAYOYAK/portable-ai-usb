#!/usr/bin/env bash
# ====================================================================
#  portable-ai-usb  ·  启动AI.sh   （macOS / Linux）
# ====================================================================
#  和 Windows 的 启动AI.bat 是同一个东西：用同一支盘、同一份 models/，
#  只是换了平台。模型文件是通用的，所以那几个 GB 的模型不用重下。
#
#  怎么用：
#     bash 启动AI.sh              # 直接启动（自动挑模型、自动挑引擎）
#     bash 启动AI.sh --list       # 看看盘里有哪些模型
#     bash 启动AI.sh --stop       # 停掉正在跑的
#     bash 启动AI.sh --help       # 全部选项
#
#  为什么是 `bash xxx.sh` 而不是 `./启动AI.sh`：
#     U 盘一般是 exFAT，exFAT 没有 Unix 权限位，chmod +x 存不住。
#     用 bash 显式调用不受这个限制。
#
#  这个脚本刻意只用 POSIX 基础工具（find/grep/sed/awk/dd/sort），
#  不依赖 bash 4 的数组特性，因为 macOS 自带的是 bash 3.2。
# ====================================================================
set -u

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SELF_DIR"
DIR_MODELS="$ROOT/models"
DIR_LLAMA="$ROOT/llama.cpp"
DIR_LOG="$ROOT/logs"
PORT_FILE="$DIR_LOG/端口.txt"

PORT=8080
CTX=""
NGL=""
LOAD_MODE="auto"
MODEL_NAME=""
DO_STOP=0
DO_LIST=0
DO_PROBE=0
DO_BENCH=0
OPEN_BROWSER=1
USE_SYSTEM_PROMPT=1     # 默认替客户端补一句"中文回答"，见下面的 DEFAULT_ZH_PROMPT
CUSTOM_PROMPT=""        # --system-prompt 传进来的自定义句子
PORT_SET=0              # 命令行有没有显式给 --port；给了就不读 端口设置.txt
LAN=0                   # --lan：让同一个 wifi 里的手机也能连
API_KEY=""              # --api-key：局域网模式下给接口上把锁
APP_VERSION="1.5.0"     # 只给 --check-update 比对用
DO_CHECK_UPDATE=0
READ_FILES=0            # --read-files：让模型能看目录里的文件（只读四件）
ALLOW_WRITE=0           # --allow-write：再加上写文件 / 改文件
TOOL_DIR=""             # --tool-dir：AI 能看见的目录（默认 <U盘>/workspace）
TOOL_DIR_FROM=""
# 采样参数：留空表示"没显式给"，按 参数设置.txt > 内置默认 的顺序定
S_TEMP=""; S_TOP_P=""; S_TOP_K=""; S_MIN_P=""; S_REPEAT=""; S_NPRED=""
PARAM_FROM="内置默认"

# ---------------------------------------------------------------- 输出
if [ -t 1 ]; then
    C_HEAD=$(printf '\033[36m'); C_OK=$(printf '\033[32m'); C_DIM=$(printf '\033[90m')
    C_WARN=$(printf '\033[33m'); C_ERR=$(printf '\033[31m'); C_OFF=$(printf '\033[0m')
else
    C_HEAD=""; C_OK=""; C_DIM=""; C_WARN=""; C_ERR=""; C_OFF=""
fi

rule() { printf '%s%s%s\n' "$C_HEAD" "  ================================================================" "$C_OFF"; }
head_line() { printf '\n'; rule; printf '    %s\n' "$1"; rule; }
ok()   { printf '      %s[OK]%s   %s\n' "$C_OK" "$C_OFF" "$1"; }
info() { printf '      %s·%s %s\n' "$C_DIM" "$C_OFF" "$1"; }
warn() { printf '      %s[注意]%s %s\n' "$C_WARN" "$C_OFF" "$1"; }
err()  { printf '\n  %s[错误]%s %s\n' "$C_ERR" "$C_OFF" "$1"; }
die()  { err "$1"; exit 1; }

# 能问就问：stdin 是管道/重定向时直接跳过，不要卡死无人值守的调用
can_ask() { [ -t 0 ]; }
pause_enter() {
    can_ask || return 0
    printf '      %s' "${1:-回车继续}"
    read -r _ 2>/dev/null || true
}

# ---------------------------------------------------------------- 小工具
# 文件字节数：不区分 GNU / BSD。stat 的标志两边含义不同（GNU 的 -f 是查文件
# 系统），所以干脆用 wc —— 它到处都一样。
file_bytes() { wc -c < "$1" 2>/dev/null | tr -d ' '; }

# 当前时间（毫秒）。BSD date 不认 %N（会原样吐出来），所以探一下。
now_ms() {
    local n
    n="$(date +%s%N 2>/dev/null || true)"
    case "$n" in
        *N*|"") printf '%s\n' "$(( $(date +%s) * 1000 ))" ;;
        *)      printf '%s\n' "$(( n / 1000000 ))" ;;
    esac
}

# 人类可读大小。awk 算，不用 du -h（两边输出格式不一致）。
human() {
    awk -v b="${1:-0}" 'BEGIN{
        split("B KB MB GB TB", u, " "); i = 1
        while (b >= 1024 && i < 5) { b /= 1024; i++ }
        if (i == 1) printf "%d %s", b, u[i]; else printf "%.2f %s", b, u[i]
    }'
}

# ---------------------------------------------------------------- 参数
show_help() {
    cat <<'HELP'
用法： bash 启动AI.sh [选项]

  （不带选项）          用默认设置启动
  --list               列出 models/ 里的模型，然后退出
  --probe              只检测硬件和选中的模型，不真启动
  --bench              测一下这支盘的读取速度，估算要等多久
  --stop               停掉正在跑的 AI，然后退出
  --model NAME         用哪个模型（文件名可以只写一部分，例如 Qwen3-4B）
  --ctx N              上下文长度（默认按内存自动定）
  --ngl N              卸载到 GPU 的层数（默认 99）
  --port N             端口（默认 8080）
  --load-mode MODE     加载方式：auto / mmap / none / mlock / mmap+mlock / dio
  --lan                让同一个 wifi / 局域网里的手机、平板也能连上用
  --api-key KEY        配合 --lan，给接口加一把钥匙（不加则同网段谁都能用）
  --no-system-prompt   不补默认的中文系统提示，让模型自己挑语言
  --system-prompt TEXT 换一句默认系统提示（只在客户端没带 system 时生效）
  --no-browser         启动后不自动开浏览器
  -h, --help           显示这段帮助

说明：
  · 模型文件（models/*.gguf）在 Windows 和 macOS / Linux 上通用，不用重下
  · 引擎不通用：各平台要有各自的一份，放在 llama.cpp/<平台>/ 下
  · 缺引擎时本脚本会告诉你该下哪一个，不会去网上乱找
  · 默认会补一句「中文回答」（借用 templates/ 里该模型自己的模板），
    客户端带了 system 或用户明说要用别的语言时都不影响
HELP
}

while [ $# -gt 0 ]; do
    case "$1" in
        --list)       DO_LIST=1 ;;
        --probe)      DO_PROBE=1 ;;
        --bench)      DO_BENCH=1 ;;
        --stop)       DO_STOP=1 ;;
        --model)      shift
                      case "${1:-}" in
                          "")   err "--model 后面要跟模型名"; printf '\n'; show_help; exit 1 ;;
                          --*)  err "--model 后面要跟模型名，不是选项：$1"; printf '\n'; show_help; exit 1 ;;
                      esac
                      MODEL_NAME="$1" ;;
        --ctx)        shift
                      case "${1:-}" in
                          ""|*[!0-9]*) err "--ctx 要一个正整数（token 数），收到「${1:-}」"; exit 1 ;;
                      esac
                      CTX="$1" ;;
        --ngl)        shift
                      case "${1:-}" in
                          ""|*[!0-9]*) err "--ngl 要一个 0 或正整数（卸载层数），收到「${1:-}」"; exit 1 ;;
                      esac
                      NGL="$1" ;;
        --port)       shift
                      case "${1:-}" in
                          ""|*[!0-9]*) err "--port 要一个端口号，收到「${1:-}」"; exit 1 ;;
                      esac
                      if [ "$1" -lt 1 ] || [ "$1" -gt 65535 ]; then
                          err "--port 要在 1~65535 之间，收到「$1」"; exit 1
                      fi
                      PORT="$1"; PORT_SET=1 ;;
        --load-mode)  shift
                      case "${1:-}" in
                          auto|mmap|none|mlock|mmap+mlock|dio) LOAD_MODE="$1" ;;
                          *) err "--load-mode 只能是 auto / mmap / none / mlock / mmap+mlock / dio，收到「${1:-}」"
                             exit 1 ;;
                      esac ;;
        --no-browser) OPEN_BROWSER=0 ;;
        --lan)        LAN=1 ;;
        --api-key)    shift
                      case "${1:-}" in
                          ""|--*) err "--api-key 后面要跟一把钥匙（随便什么字符串）"; printf '\n'; show_help; exit 1 ;;
                      esac
                      API_KEY="$1" ;;
        --no-system-prompt) USE_SYSTEM_PROMPT=0 ;;
        --system-prompt) shift
                      case "${1:-}" in
                          ""|--*) err "--system-prompt 后面要跟一句话"; printf '\n'; show_help; exit 1 ;;
                      esac
                      CUSTOM_PROMPT="$1" ;;
        --read-files)  READ_FILES=1 ;;
        --allow-write) ALLOW_WRITE=1; READ_FILES=1 ;;
        --tool-dir)    shift
                       case "${1:-}" in
                           ""|--*) err "--tool-dir 后面要跟一个目录"; printf '\n'; show_help; exit 1 ;;
                       esac
                       TOOL_DIR="$1" ;;
        --temp)        shift; S_TEMP="${1:-}" ;;
        --top-p)       shift; S_TOP_P="${1:-}" ;;
        --top-k)       shift; S_TOP_K="${1:-}" ;;
        --min-p)       shift; S_MIN_P="${1:-}" ;;
        --repeat-penalty) shift; S_REPEAT="${1:-}" ;;
        --n-predict)   shift; S_NPRED="${1:-}" ;;
        --check-update) DO_CHECK_UPDATE=1 ;;
        -h|--help)    show_help; exit 0 ;;
        *)            err "不认识的选项：$1"; printf '\n'; show_help; exit 1 ;;
    esac
    shift
done

# ---- U 盘根目录的设置文件（Windows 侧 高级选项.bat 的 [16] 写它们）----
# 命令行优先：显式给了 --port / --system-prompt 就不读文件，
# 免得临时指定被动过的文件悄悄盖掉。两个文件都不存在时行为完全不变。
#
# 注意 端口设置.txt 和 logs/端口.txt 不是一回事：
#   端口设置.txt 是**输入**（你想要哪个号）
#   logs/端口.txt 是**输出**（8080 被占用时自动换到了哪个号）
PORT_FROM=""
if [ "$PORT_SET" -eq 0 ] && [ -f "$ROOT/端口设置.txt" ]; then
    _pt="$(tr -d ' \t\r\n' < "$ROOT/端口设置.txt" 2>/dev/null || true)"
    case "$_pt" in
        ''|*[!0-9]*) warn "端口设置.txt 里不是合法端口（要 1024~65535），这次仍用 $PORT" ;;
        *)
            if [ "$_pt" -ge 1024 ] && [ "$_pt" -le 65535 ]; then
                PORT="$_pt"; PORT_FROM="端口设置.txt"
            else
                warn "端口设置.txt 里不是合法端口（要 1024~65535），这次仍用 $PORT"
            fi
            ;;
    esac
fi

FILE_PROMPT=""
if [ -f "$ROOT/系统提示.txt" ]; then
    FILE_PROMPT="$(cat "$ROOT/系统提示.txt" 2>/dev/null | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' || true)"
fi

# ---------------------------------------------------------------- 平台
# ---- --check-update：只问一句有没有新版，然后退出 ----
if [ "$DO_CHECK_UPDATE" = 1 ]; then
    REPO_SLUG="KAYOYAK/portable-ai-usb"
    _latest="$(curl -fsSL -m 8 "https://api.github.com/repos/$REPO_SLUG/releases/latest" 2>/dev/null \
               | sed -n "s/.*\"tag_name\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n 1)"
    printf '\n'
    printf '  当前版本 :  v%s\n' "$APP_VERSION"
    if [ -z "$_latest" ]; then
        warn "查不到（可能没联网）。手动去： https://github.com/$REPO_SLUG/releases"
    elif [ "$_latest" = "v$APP_VERSION" ]; then
        printf '  已经是最新的。\n'
    else
        printf '  最新版本 :  %s\n' "$_latest"
        printf '  下载地址 :  https://github.com/%s/releases/tag/%s\n' "$REPO_SLUG" "$_latest"
    fi
    printf '\n'
    exit 0
fi

OS="$(uname -s)"
ARCH="$(uname -m)"
case "$OS" in
    Darwin) PLATFORM_OS="macos" ;;
    Linux)  PLATFORM_OS="linux" ;;
    *)      die "这个启动器只认 macOS 和 Linux，当前是 $OS。Windows 请用 启动AI.bat。" ;;
esac

# 引擎目录名对齐官方 release 资产名，方便照着下
ENGINE_CANDIDATES=""
ENGINE_FIRST=""
case "$PLATFORM_OS/$ARCH" in
    macos/arm64)   ENGINE_CANDIDATES="macos-arm64";                        ENGINE_FIRST="macos-arm64" ;;
    macos/x86_64)  ENGINE_CANDIDATES="macos-x64";                          ENGINE_FIRST="macos-x64" ;;
    linux/x86_64)  ENGINE_CANDIDATES="ubuntu-vulkan-x64 ubuntu-x64 ubuntu-cuda-12.8-x64"
                   ENGINE_FIRST="ubuntu-vulkan-x64" ;;
    linux/aarch64) ENGINE_CANDIDATES="ubuntu-vulkan-arm64 ubuntu-arm64";   ENGINE_FIRST="ubuntu-vulkan-arm64" ;;
esac

# ---------------------------------------------------------------- 找引擎
find_engine() {
    for name in $ENGINE_CANDIDATES; do
        # 用 -f 不用 -x：U 盘多半是 exFAT / FAT32，这类文件系统没有可执行位，
        # 挂载参数不同会给成 0644 或 0755 —— 拿 -x 判，会把已经拷好的引擎判成"没有"，
        # 然后让人白下一遍。真没有执行权限时，启动那一步会给出具体提示。
        if [ -f "$DIR_LLAMA/$name/llama-server" ]; then
            printf '%s\n' "$DIR_LLAMA/$name/llama-server"; return 0
        fi
    done
    # 系统里装好的（brew / apt / 源码编译）
    if command -v llama-server >/dev/null 2>&1; then
        command -v llama-server; return 0
    fi
    return 1
}

engine_hint() {
    tag="b11270"
    asset=""
    case "$PLATFORM_OS/$ARCH" in
        macos/arm64)   asset="llama-$tag-bin-macos-arm64.tar.gz" ;;
        macos/x86_64)  asset="llama-$tag-bin-macos-x64.tar.gz" ;;
        linux/x86_64)  asset="llama-$tag-bin-ubuntu-x64.tar.gz" ;;
        linux/aarch64) asset="llama-$tag-bin-ubuntu-arm64.tar.gz" ;;
    esac
    printf '\n'
    warn "这支盘里没有 $PLATFORM_OS/$ARCH 的引擎。"
    if [ -z "$asset" ] || [ -z "$ENGINE_FIRST" ]; then
        warn "官方 release 里没有这个组合的预编译包，需要自己编译 llama.cpp。"
        info "源码： https://github.com/ggml-org/llama.cpp"
        return
    fi
    info "两个办法，任选一个："
    printf '\n      %s办法一：装到系统里（最省事）%s\n' "$C_DIM" "$C_OFF"
    if [ "$PLATFORM_OS" = "macos" ]; then
        info "brew install llama.cpp"
    else
        info "看你发行版：apt install llama.cpp  或  pacman -S llama.cpp"
    fi
    printf '\n      %s办法二：下进这支盘（能带走，换电脑不用重装）%s\n' "$C_DIM" "$C_OFF"
    info "curl -L -o /tmp/$asset \\"
    info "  https://github.com/ggml-org/llama.cpp/releases/download/$tag/$asset"
    info "mkdir -p \"$DIR_LLAMA/$ENGINE_FIRST\""
    info "tar -xzf /tmp/$asset -C \"$DIR_LLAMA/$ENGINE_FIRST\" --strip-components=1"
    printf '\n'
    info "（Windows 那份引擎在盘里还是好的，只是这台机器用不上。）"
}

# ---------------------------------------------------------------- 找模型
list_models() {
    find "$DIR_MODELS" -maxdepth 1 -name '*.gguf' -type f ! -name 'mmproj-*' 2>/dev/null
}

# 按体积从大到小排好，输出"字节数<TAB>路径"
models_by_size() {
    list_models | while IFS= read -r f; do
        [ -n "$f" ] || continue
        printf '%s\t%s\n' "$(file_bytes "$f")" "$f"
    done | sort -rn
}

show_models() {
    if [ -z "$(list_models)" ]; then
        warn "models/ 里一个模型都没有"
        return
    fi
    printf '      %smodels/ 里现在有：%s\n' "$C_DIM" "$C_OFF"
    models_by_size | while IFS="$(printf '\t')" read -r sz f; do
        [ -n "$f" ] || continue
        printf '        %-44s %10s\n' "$(basename "$f")" "$(human "$sz")"
    done
    if [ -f "$DIR_MODELS/当前模型.txt" ]; then
        printf '      %s当前模型.txt 指定：%s%s\n' "$C_DIM" "$(tr -d '\r\n' < "$DIR_MODELS/当前模型.txt")" "$C_OFF"
    else
        printf '      %s（没有 当前模型.txt，启动时自动用最大的那个）%s\n' "$C_DIM" "$C_OFF"
    fi
}

# 把"大概的名字"解析成具体文件 —— 规则和 Windows 那份完全一致：
#   ① 完整文件名精确匹配  ② 补 .gguf 后精确匹配
#   ③ 不区分大小写的子串，只有唯一命中才算
# 多命中就把候选都打印出来让人自己挑，绝不猜。
#
# 用返回码区分类别，不用全局变量：这个函数是在 $( ) 里调用的，而命令替换
# 会开子 shell —— 函数里设的变量传不回来（这个坑真踩过）。
#   0 = 唯一命中，stdout 是那个文件
#   1 = 多个命中，stdout 是所有候选
#   2 = 一个都没命中，stdout 为空
resolve_model() {
    want="$1"
    # 比的是**文件名**，不是路径。
    # list_models 吐出来的是绝对路径，直接 `grep -Fx "$want"` 拿裸文件名去比永远不中；
    # 而子串那一档如果拿整条路径去比，盘路径里碰巧出现 "ai"、"tmp" 就会静默选中某个模型。
    # 所以先把每个候选剥成 basename 再比 —— 和 Windows 那份（比 $_.Name）对齐。
    # 三档都按大小写不敏感比，也对齐 PowerShell 的 -eq / OrdinalIgnoreCase。
    lwant="$(printf '%s' "$want" | tr '[:upper:]' '[:lower:]')"

    # ①②档：完整文件名 / 补 .gguf 后完整文件名
    hits="$(list_models | while IFS= read -r l; do
                lb="$(basename "$l" | tr '[:upper:]' '[:lower:]')"
                if [ "$lb" = "$lwant" ] || [ "$lb" = "$lwant.gguf" ]; then
                    printf '%s\n' "$l"
                fi
            done)"
    # ③档：子串，只有唯一命中才算数
    if [ -z "$hits" ]; then
        hits="$(list_models | while IFS= read -r l; do
                    lb="$(basename "$l" | tr '[:upper:]' '[:lower:]')"
                    case "$lb" in
                        *"$lwant"*) printf '%s\n' "$l" ;;
                    esac
                done)"
    fi
    [ -n "$hits" ] || return 2
    # 注意：grep -c 匹配到 0 个时退出码是 1，所以后面只能接 `|| true`，
    # 不能接 `|| printf '0'` —— 那会往 stdout 再塞一个 0，把 $n 变成两行。
    n="$(printf '%s\n' "$hits" | grep -c . 2>/dev/null || true)"
    [ "$n" -eq 1 ] && { printf '%s\n' "$hits"; return 0; }
    printf '%s\n' "$hits"
    return 1
}

# 打印多命中候选，缩进对齐
show_candidates() {
    printf '%s\n' "$1" | while IFS= read -r l; do
        [ -n "$l" ] && printf '        %s\n' "$(basename "$l")"
    done
}

# ---------------------------------------------------------------- 停止
do_stop() {
    if ! command -v pgrep >/dev/null 2>&1; then
        warn "这台机器没有 pgrep，只能自己 kill 了："
        info "ps aux | grep llama-server"
        return 1
    fi
    # 只认"本盘路径"下跑起来的，别的程序起的 llama-server 不碰。
    # 盘路径要先转义再拼进正则：路径里的 . + [ ( 这些本来就是正则元字符，
    # /Volumes/AI.1 会连 /Volumes/AIx1 一起匹配上，那就可能误伤别的盘的进程。
    esc_dir="$(printf '%s' "$DIR_LLAMA" | sed 's/[][\\.^$*+?(){}|]/\\&/g')"
    pids="$(pgrep -f "$esc_dir.*llama-server" 2>/dev/null || true)"
    killed=0
    for p in $pids; do
        if kill "$p" 2>/dev/null; then
            ok "已停止进程 $p"
            killed=$((killed+1))
        fi
    done
    if [ "$killed" -eq 0 ]; then
        info "没有找到本盘启动的 llama-server（别的程序跑的不会被动）。"
    fi
    return 0
}

# ================================================================ 主流程
head_line "U盘 AI 便携版  ·  llama.cpp   （$PLATFORM_OS / $ARCH）"
printf '  启动位置 : %s\n' "$ROOT"

if [ "$DO_STOP" = 1 ]; then
    # 把返回码透出去：没有 pgrep 的机器上啥也没停成，不能还报 0。
    # （"本来就没有在跑"那一支仍是 0 —— 那种情况停止是幂等的，不算失败。）
    do_stop
    exit $?
fi

if [ ! -d "$DIR_MODELS" ]; then
    err "找不到 models 目录 —— 这支盘还没准备好"
    info "期望位置：$DIR_MODELS"
    info "把 Windows 上装好的那支盘直接拿过来就能用，模型是通用的。"
    pause_enter; exit 1
fi

if [ "$DO_LIST" = 1 ]; then
    show_models
    exit 0
fi

# ---- 挑模型 ----
MODEL=""
SOURCE=""
if [ -n "$MODEL_NAME" ]; then
    # 先把结果接住再看返回码：命令替换会把"赋了值"和"成功了"这两件事分开，
    # 不接住的话多命中时 $MODEL 会被塞进一整列文件名。
    out="$(resolve_model "$MODEL_NAME")"; rc=$?
    case "$rc" in
        0) MODEL="$out"; SOURCE="命令行 --model 指定" ;;
        1) err "「$MODEL_NAME」匹配到多个模型，说不准用哪个："
           show_candidates "$out"
           printf '\n'; show_models; pause_enter; exit 1 ;;
        *) err "models/ 里找不到「$MODEL_NAME」"
           printf '\n'; show_models; pause_enter; exit 1 ;;
    esac
elif [ -f "$DIR_MODELS/当前模型.txt" ]; then
    # 清掉 BOM、行尾和首尾空白再比。手工用记事本"另存为 UTF-8"会带上 BOM，
    # 手滑多敲一个空格也很常见 —— 脏串会让匹配整个偏掉，而用户看不出为什么。
    want="$(tr -d '\357\273\277\r\n' < "$DIR_MODELS/当前模型.txt" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    if [ -n "$want" ]; then
        out="$(resolve_model "$want")"; rc=$?
        if [ "$rc" -eq 0 ]; then
            MODEL="$out"; SOURCE="当前模型.txt 指定"
        else
            warn "当前模型.txt 里写的「$want」没法唯一确定，改回自动选最大的。"
        fi
    else
        warn "当前模型.txt 是空的，按体积最大的选。"
    fi
fi

if [ -z "$MODEL" ]; then
    MODEL="$(models_by_size | head -1 | cut -f2-)"
    SOURCE="自动（体积最大）"
fi

if [ -z "$MODEL" ] || [ ! -f "$MODEL" ]; then
    err "models/ 里一个 .gguf 都没有"
    info "模型是单独下载的（几个 GB），不在 Git 仓库里。"
    info "可以在 Windows 上用 tools 里的「换模型」下好，U 盘拿过来直接用。"
    pause_enter; exit 1
fi

MODEL_BASE="$(basename "$MODEL")"
MODEL_ALIAS="${MODEL_BASE%.gguf}"
MODEL_BYTES="$(file_bytes "$MODEL")"
# 读不到就按 0 处理并说一声：这个数下面要参与测速折算和内存判断，
# 留空会让算术里静默按 0 走，反而不如明说。
if [ -z "$MODEL_BYTES" ]; then
    MODEL_BYTES=0
    warn "读不到模型文件的大小（权限或介质问题？）—— 下面按 0 处理。"
fi
MODEL_HUMAN="$(human "$MODEL_BYTES")"

printf '  模型     : %s%s%s  (%s)\n' "$C_OK" "$MODEL_BASE" "$C_OFF" "$SOURCE"
printf '  模型大小 : %s\n' "$MODEL_HUMAN"

# ---- 多模态投影文件 ----
# 和 Windows 那份同一套逻辑：找到就显式指过去，没找到就显式关掉。
# 关掉不是可选项 —— 引擎在「没给投影文件」时存在自己去下的路径，那就要联网，
# 而这个盘的卖点之一就是首次启动完全离线。
MMPROJ=""
if [ -d "$DIR_MODELS" ]; then
    # 取体积最大的那个，和 Windows 那份一致（launcher.ps1 按体积降序取第一个）。
    # 原来是 find | head -1，拿的是 find 遍历顺序里碰巧排最前的那个 ——
    # 盘里同时放着 f16 和 q4_0 两份投影文件时，会挑到小的那份。
    MMPROJ="$(ls -S "$DIR_MODELS"/mmproj-*.gguf 2>/dev/null | head -1)"
    [ -f "$MMPROJ" ] || MMPROJ=""
fi
if [ -n "$MMPROJ" ]; then
    printf '  看图能力 : %s开%s  (%s)\n' "$C_OK" "$C_OFF" "$(basename "$MMPROJ")"
else
    printf '  看图能力 : %s关%s  (models/ 里没有 mmproj-*.gguf)\n' "$C_DIM" "$C_OFF"
fi

if [ "$(list_models | grep -c . 2>/dev/null || printf 0)" -gt 1 ]; then
    info "models/ 里有多个模型。想换：--model 名字   或加 --list 看全部"
fi

# ---- 引擎 ----
ENGINE="$(find_engine || true)"
if [ -z "$ENGINE" ]; then
    engine_hint
    pause_enter; exit 1
fi
case "$ENGINE" in
    "$ROOT"/*) printf '  引擎     : %s\n' "${ENGINE#$ROOT/}" ;;
    *)         printf '  引擎     : %s  (系统里装的)\n' "$ENGINE" ;;
esac

# 引擎目录名顺便当"加速方式"显示。措辞跟 Windows 侧 launcher.ps1 的 $backendName 对齐，
# 免得同一台机器上两个平台各说各话。
BACKEND_SHOWN="$(basename "$(dirname "$ENGINE")")"
BACKEND_FULL="$BACKEND_SHOWN"
case "$BACKEND_SHOWN" in
    *cuda*)          BACKEND_FULL="NVIDIA CUDA  (显卡加速)   [$BACKEND_SHOWN]" ;;
    *vulkan*)        BACKEND_FULL="Vulkan  (AMD / Intel / 老NVIDIA 通用加速)   [$BACKEND_SHOWN]" ;;
    *macos*|*metal*) BACKEND_FULL="Metal  (Apple 显卡加速)   [$BACKEND_SHOWN]" ;;
    *cpu*|x64|arm64) BACKEND_FULL="纯 CPU  (兼容模式，慢)   [$BACKEND_SHOWN]" ;;
    *)               BACKEND_FULL="$BACKEND_SHOWN  (不确定是哪份引擎，看目录名)" ;;
esac

# ---- 硬件 ----
CPU_CORES="$( (command -v nproc >/dev/null 2>&1 && nproc) || sysctl -n hw.ncpu 2>/dev/null || printf 4)"
THREADS=$(( CPU_CORES > 8 ? 8 : CPU_CORES ))

RAM_GB=0
if [ "$PLATFORM_OS" = "macos" ]; then
    RAM_GB="$(sysctl -n hw.memsize 2>/dev/null | awk '{printf "%.0f", $1/1024/1024/1024}')"
elif [ -r /proc/meminfo ]; then
    RAM_GB="$(awk '/MemTotal/{printf "%.0f", $2/1024/1024}' /proc/meminfo)"
fi
[ -n "$RAM_GB" ] || RAM_GB=0

# macOS 走 Metal（统一内存），Linux 上看引擎是哪份：vulkan/cuda 才真能卸载
if [ -z "$NGL" ]; then
    case "$ENGINE" in
        *vulkan*|*cuda*|*macos*) NGL=99 ;;
        *) NGL=99 ;;
    esac
fi

if [ -z "$CTX" ]; then
    if [ "$RAM_GB" -ge 16 ] 2>/dev/null; then CTX=32768; else CTX=8192; fi
fi

KV_TYPE="q8_0"
if [ "$RAM_GB" -gt 0 ] 2>/dev/null && [ "$RAM_GB" -lt 12 ] 2>/dev/null; then
    KV_TYPE="q4_0"
fi
# 真正传给引擎的 KV 量化，和上面"打算用哪种"是两件事：
# --cache-type-* 只有 vulkan / cuda 那两份引擎带，macOS 走 Metal 不传。
# 显示的时候必须看这个，否则会在 Mac 上打出"KV 缓存 q4_0"而实际没生效 —— 
# 那种"看着省了内存其实没省"的误导比不显示更糟。
KV_SHOWN=""

# ---- 局域网地址（--lan 才需要）----
# 取「默认路由走的那张网卡」的地址，而不是 ifconfig 里翻出来的第一个 ——
# 装了 Docker / 虚拟机的人机器上有一堆 172.17.x、192.168.56.x，翻错了给别人一个连不上的地址。
HOST_ARG="127.0.0.1"
LAN_IP=""
if [ "$LAN" = 1 ]; then
    case "$PLATFORM_OS" in
        macos)
            _if="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')"
            [ -n "$_if" ] && LAN_IP="$(ipconfig getifaddr "$_if" 2>/dev/null)"
            ;;
        linux)
            LAN_IP="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
            ;;
    esac
    case "$LAN_IP" in
        ""|127.*|169.254.*) LAN_IP="" ;;
    esac
    if [ -n "$LAN_IP" ]; then
        HOST_ARG="127.0.0.1,$LAN_IP"
    else
        warn "没找到局域网地址（这台电脑没连路由器？）—— 本次只能本机用。"
        LAN=0
    fi
fi

# ---- 默认系统提示 ----
# 和 Windows 侧同一套做法：引擎没有"默认 system"这种参数，模型的模板里也没有对应变量，
# 唯一可行的办法是借模型自己那份模板改三行。所以匹配不上就绝不硬套 ——
# 换了模型还拿旧格式的模板去喂，输出会整段烂掉。
DEFAULT_ZH_PROMPT="中文回答。不要出现英文单词。需要读文件就直接调工具。"
TPL_FILE=""
TPL_NOTE=""
SYS_PROMPT=""
if [ "$USE_SYSTEM_PROMPT" = 1 ]; then
    # 优先级：--system-prompt > 系统提示.txt > 内置那句。
    # 系统提示.txt 由 Windows 侧的 高级选项.bat [16] 写；也可以手写一个。
    if   [ -n "$CUSTOM_PROMPT" ]; then SYS_PROMPT="$CUSTOM_PROMPT"; PROMPT_FROM="--system-prompt"
    elif [ -n "$FILE_PROMPT" ];   then SYS_PROMPT="$FILE_PROMPT";   PROMPT_FROM="系统提示.txt"
    else                               SYS_PROMPT="$DEFAULT_ZH_PROMPT"; PROMPT_FROM="内置默认"
    fi
    if [ -d "$ROOT/templates" ]; then
        for _f in "$ROOT"/templates/*.jinja; do
            [ -f "$_f" ] || continue
            _base="$(basename "$_f" .jinja)"
            case "$MODEL_BASE" in
                "$_base"*) TPL_FILE="$_f"; break ;;
            esac
        done
    fi
    if [ -z "$TPL_FILE" ]; then
        TPL_NOTE="想让模型默认说中文，但 templates/ 里没有匹配 $MODEL_BASE 的模板 —— 本次不注入。"
        SYS_PROMPT=""
    fi
fi

# ---- 采样参数：参数设置.txt > 内置默认 ----
# 和 Windows 侧同构；命令行 --temp 之类显式给了就不再被文件盖掉。
PARAM_FILE="$ROOT/参数设置.txt"
if [ -f "$PARAM_FILE" ]; then
    while IFS= read -r _line || [ -n "$_line" ]; do
        case "$_line" in ''|'#'*) continue ;; esac
        # 全角冒号/等号在字节层会被拆坏：先统一成半角再切
        _line="$(printf '%s' "$_line" | sed "s/：/:/g; s/＝/=/g")"
        _k="$(printf '%s' "${_line%%[=:：]*}" | tr -d ' \t\r')"
        _v="$(printf '%s' "${_line#*[=:：]}" | tr -d ' \t\r')"
        [ -n "$_k" ] || continue
        case "$_k" in
            temp)           [ -z "$S_TEMP" ]   && S_TEMP="$_v" ;;
            top_p)          [ -z "$S_TOP_P" ]  && S_TOP_P="$_v" ;;
            top_k)          [ -z "$S_TOP_K" ]  && S_TOP_K="$_v" ;;
            min_p)          [ -z "$S_MIN_P" ]  && S_MIN_P="$_v" ;;
            repeat_penalty) [ -z "$S_REPEAT" ] && S_REPEAT="$_v" ;;
            n_predict)      [ -z "$S_NPRED" ]  && S_NPRED="$_v" ;;
        esac
    done < "$PARAM_FILE"
    PARAM_FROM="参数设置.txt"
fi
[ -n "$S_TEMP" ]   || S_TEMP="0.6"
[ -n "$S_TOP_P" ]  || S_TOP_P="0.95"
[ -n "$S_TOP_K" ]  || S_TOP_K="20"
[ -n "$S_MIN_P" ]  || S_MIN_P="0"
[ -n "$S_REPEAT" ] || S_REPEAT="1.1"
[ -n "$S_NPRED" ]  || S_NPRED="-1"

# ---- 让 AI 读文件 / 改文件 ----
# 引擎内置工具，通过 --tools 打开；开启后引擎自己会把 CORS 限制到 localhost。
TOOLS_ON=0
TOOLS_LIST=""
TOOL_NOTE=""
if [ "$READ_FILES" = 1 ] || [ "$ALLOW_WRITE" = 1 ]; then
    TOOLS_ON=1
    if [ -z "$TOOL_DIR" ]; then TOOL_DIR="$ROOT/workspace"; TOOL_DIR_FROM="默认"
    else                            TOOL_DIR_FROM="--tool-dir"
    fi
    mkdir -p "$TOOL_DIR" 2>/dev/null || true
    # exec_shell_command 故意不给：Windows 上是 cmd，中文输出会变成问号，
    # 而且"能执行命令"和"能改文件"是两件事，不该顺带一起给。
    if [ "$ALLOW_WRITE" = 1 ]; then
        TOOLS_LIST="read_file,file_glob_search,grep_search,get_info,write_file,edit_file"
    else
        TOOLS_LIST="read_file,file_glob_search,grep_search,get_info"
    fi
    if printf '%s' "$TOOL_DIR" | LC_ALL=C grep -q '[^ -~]'; then
        TOOL_NOTE="目录名里有非 ASCII 字符，引擎列举文件时可能报错 —— 建议换成纯英文目录名。"
    fi
    if [ -n "$SYS_PROMPT" ]; then
        SYS_PROMPT="$SYS_PROMPT文件都在当前目录，路径直接写文件名就行。这个系统是 $(uname -s)。改文件用 write_file 或 edit_file，不要用命令行改。"
    fi
fi

# ---- 拼参数 ----
set -- \
    -m "$MODEL" \
    --alias "$MODEL_ALIAS" \
    --host "$HOST_ARG" \
    --port "$PORT" \
    --n-gpu-layers "$NGL" \
    --ctx-size "$CTX" \
    --threads "$THREADS" \
    --jinja \
    --reasoning-format deepseek \
    --temp "$S_TEMP" --top-p "$S_TOP_P" --top-k "$S_TOP_K" --min-p "$S_MIN_P" \
    --repeat-penalty "$S_REPEAT" --n-predict "$S_NPRED"

# 只有 vulkan/cuda 那两份引擎才有这两个开关；macOS 的 Metal 交给引擎自己定
case "$ENGINE" in
    *vulkan*|*cuda*)
        set -- "$@" --flash-attn on --cache-type-k "$KV_TYPE" --cache-type-v "$KV_TYPE"
        KV_SHOWN="$KV_TYPE" ;;
esac

LOAD_NOTE=""
if [ "$LOAD_MODE" != "auto" ]; then
    case "$LOAD_MODE" in
        none|mlock|mmap+mlock)
            need=$(( MODEL_BYTES / 1024 / 1024 / 1024 + 2 ))
            if [ "$RAM_GB" -gt 0 ] 2>/dev/null && [ "$RAM_GB" -lt "$need" ] 2>/dev/null; then
                warn "内存只有 $RAM_GB GB，装不下 $MODEL_HUMAN 的模型加开销 —— 加载方式已改回 auto。"
                LOAD_NOTE="（原指定 $LOAD_MODE，内存不够已回退）"
                LOAD_MODE="auto"
            fi ;;
    esac
    [ "$LOAD_MODE" != "auto" ] && set -- "$@" -lm "$LOAD_MODE"
fi

if [ -n "$MMPROJ" ]; then
    set -- "$@" -mm "$MMPROJ"
else
    set -- "$@" --no-mmproj
fi

# 内层引号必须转成 \" 才能穿过引擎的参数解析。少了引号的 JSON 是残废的，引擎直接
# 报错退出：invalid literal; last read: '{d'; expected string literal —— 这个坑在
# Windows 侧踩过一次，两边都得转。
if [ -n "$TPL_FILE" ] && [ -n "$SYS_PROMPT" ]; then
    KW="$(printf '{"default_system":"%s"}' "$SYS_PROMPT" | sed 's/"/\\"/g')"
    set -- "$@" --chat-template-file "$TPL_FILE" --chat-template-kwargs "$KW"
fi

if [ "$TOOLS_ON" = 1 ]; then
    set -- "$@" --tools "$TOOLS_LIST"
fi

# 引擎没设钥匙时会自己打一行 "no API key is set and CORS allows all origins"。
# 只在本机跑无所谓；一旦开了局域网，同一个 wifi 下谁都能用。
if [ "$LAN" = 1 ] && [ -n "$API_KEY" ]; then
    set -- "$@" --api-key "$API_KEY"
fi

printf '\n'
printf '  %s上下文   : %s tokens%s\n' "$C_DIM" "$CTX" "$C_OFF"
printf '  显存卸载 : %s 层\n' "$NGL"
if [ -n "$KV_SHOWN" ]; then
    printf '  KV 缓存  : %s\n' "$KV_SHOWN"
else
    printf '  KV 缓存  : %s\n' "引擎默认（这份引擎不接受这个开关）"
fi
printf '  CPU 线程 : %s  (本机 %s 核)\n' "$THREADS" "$CPU_CORES"
printf '  内存     : %s GB\n' "$RAM_GB"
printf '  端口     : %s%s\n' "$PORT" "$([ -n "$PORT_FROM" ] && printf '  （来源：%s）' "$PORT_FROM")"
[ "$LOAD_MODE" != "auto" ] && printf '  加载方式 : %s %s\n' "$LOAD_MODE" "$LOAD_NOTE"
if [ "$LAN" = 1 ]; then
    printf '  局域网   : 开   ->   http://%s:%s\n' "$LAN_IP" "$PORT"
    printf '              %s手机/平板连同一个 wifi，浏览器打开上面这个地址%s\n' "$C_DIM" "$C_OFF"
    [ -z "$API_KEY" ] && printf '              %s[注意] 没设钥匙，同一个网络里任何人都能用%s\n' "$C_WARN" "$C_OFF"
fi
if [ -n "$TPL_FILE" ] && [ -n "$SYS_PROMPT" ]; then
    printf '  系统提示 : 开   %s(来源：%s；客户端没带 system 时补：%s)%s\n' "$C_DIM" "$PROMPT_FROM" "$SYS_PROMPT" "$C_OFF"
elif [ "$USE_SYSTEM_PROMPT" = 0 ]; then
    printf '  系统提示 : 关   %s(--no-system-prompt)%s\n' "$C_DIM" "$C_OFF"
fi
[ -n "$TPL_NOTE" ] && printf '\n  %s[注意] %s%s\n' "$C_WARN" "$TPL_NOTE" "$C_OFF"
if [ "$TOOLS_ON" = 1 ]; then
    if [ "$ALLOW_WRITE" = 1 ]; then _scope="读 + 写（不含执行命令）"; else _scope="只读"; fi
    printf '  读文件   :  开   %s(%s)%s   ->   %s\n' "$C_DIM" "$_scope" "$C_OFF" "$TOOL_DIR"
    [ "$LAN" = 1 ] && printf '              %s[注意] 开了局域网又开了写权限，同一个 wifi 下别人也能让 AI 改文件%s\n' "$C_WARN" "$C_OFF"
    [ -n "$TOOL_NOTE" ] && printf '\n  %s[注意] %s%s\n' "$C_WARN" "$TOOL_NOTE" "$C_OFF"
fi
printf '  采样     :  temp %s / top_p %s / top_k %s / min_p %s%s\n' "$S_TEMP" "$S_TOP_P" "$S_TOP_K" "$S_MIN_P" "$([ "$PARAM_FROM" = "参数设置.txt" ] && printf '   （来源：参数设置.txt）')"

# ---- 当前设置.txt ----
# 和 Windows 侧同名同格式：一份人能读的"这次按什么配置跑的"。
# 以前这些只在这块终端里出现过，关了就没了。
_write_settings() {
    _sf="$ROOT/当前设置.txt"
    {
        printf 'U盘 AI 便携版 —— 当前设置\n'
        printf '（每次启动自动刷新，可以随时打开看；改这里没用，改完重启就被覆盖）\n'
        printf '\n'
        printf '生成时间 :  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
        printf '启动位置 :  %s\n' "$ROOT"
        printf '运行平台 :  %s %s\n' "$OS" "$ARCH"
        printf '\n'
        printf '模型     :  %s   (%s GB)\n' "$MODEL_BASE" "$MODEL_GB"
        printf '加速方式 :  %s\n' "$BACKEND_FULL"
        printf '上下文   :  %s tokens\n' "$CTX"
        printf '显存卸载 :  %s 层   (KV 缓存 %s)\n' "$NGL" "${KV_SHOWN:-默认}"
        printf 'CPU 线程 :  %s\n' "$THREADS"
        printf '加载方式 :  %s\n' "$LOAD_MODE"
        printf '端口     :  %s%s\n' "$PORT" "$([ -n "$PORT_FROM" ] && printf '   （来源：%s）' "$PORT_FROM")"
        printf '网页界面 :  http://127.0.0.1:%s\n' "$PORT"
        printf '采样参数 :  temp %s / top_p %s / top_k %s / min_p %s / repeat %s / n_predict %s   （来源：%s）\n' "$S_TEMP" "$S_TOP_P" "$S_TOP_K" "$S_MIN_P" "$S_REPEAT" "$S_NPRED" "$PARAM_FROM"
        if [ "$TOOLS_ON" = 1 ]; then
            printf '读文件   :  开   （AI 只能看到 %s）\n' "$TOOL_DIR"
        else
            printf '读文件   :  关\n'
        fi
        if [ "$LAN" = 1 ]; then
            printf '局域网   :  开   ->   http://%s:%s\n' "$LAN_IP" "$PORT"
        else
            printf '局域网   :  关\n'
        fi
        printf '\n'
        if [ -n "$TPL_FILE" ] && [ -n "$SYS_PROMPT" ]; then
            printf '系统提示 :  开   （来源：%s）\n' "$PROMPT_FROM"
            printf '            只在客户端自己没发 system 消息时补上；\n'
            printf '            客户端带了就听客户端的，不会被覆盖、也不会重复注入。\n'
            printf '\n'
            printf '            原文： %s\n' "$SYS_PROMPT"
            printf '\n'
            printf '            想改：直接编辑 %s/系统提示.txt 后重启。\n' "$ROOT"
        elif [ "$USE_SYSTEM_PROMPT" = 0 ]; then
            printf '系统提示 :  关   （--no-system-prompt，模型按自己的脾气挑语言）\n'
        else
            printf '系统提示 :  关   （没找到匹配这个模型的模板，见 templates/）\n'
        fi
    } > "$_sf" 2>/dev/null || true
}
_write_settings

if [ "$DO_PROBE" = 1 ]; then
    head_line "探测完成（没有真的启动引擎）"
    printf '  模型  = %s\n' "$MODEL_BASE"
    printf '  ctx   = %s        ngl = %s        kv = %s\n' "$CTX" "$NGL" "${KV_SHOWN:-默认}"
    printf '  内存  = %s GB     线程 = %s\n' "$RAM_GB" "$THREADS"
    exit 0
fi

# ---- 测速 ----
# 说明：这里测的是「接近真实」的顺序读，不声称绕过了系统缓存 ——
# 真要绕过得自己写 O_DIRECT，为它引一堆代码不值得。缓存命中时会明确说出来。
if [ "$DO_BENCH" = 1 ]; then
    # 每段读 32 MB，但模型文件可能比这小得多 —— 这时 dd 会提前 EOF，
    # 而按 32 MB 折算速度就会报出"6 MB 的模型读 431 MB/s"这种假数。
    # 所以每段实际读多少先算出来，速度按真正读到的量算；实在太小就直说测不了。
    usable_mb=$(( MODEL_BYTES / 1048576 ))
    if [ "$usable_mb" -lt 32 ]; then
        warn "模型只有 ${usable_mb} MB，太小了，测不出这支盘的速度。"
        info "盘上放一个几百 MB 以上的模型再测；或者用 Windows 那份启动器的 [11]（它按字节真读）。"
        pause_enter; exit 0
    fi
    step=0
    total=0
    printf '\n  正在读 3 段，每段最多 32 MB……\n'
    for frac in 20 55 80; do
        off_mb=$(( usable_mb * frac / 100 ))
        left_mb=$(( usable_mb - off_mb ))
        this_mb=32
        if [ "$this_mb" -gt "$left_mb" ]; then this_mb="$left_mb"; fi
        # 段太小时读出来的是抖动，不是速度 —— 跳过，别拿它凑平均
        if [ "$this_mb" -lt 8 ]; then continue; fi
        t0="$(now_ms)"
        dd if="$MODEL" of=/dev/null bs=1048576 count="$this_mb" skip="$off_mb" 2>/dev/null || true
        t1="$(now_ms)"
        ms=$(( t1 - t0 ))
        [ "$ms" -gt 0 ] || ms=1
        mbps=$(( this_mb * 1000 / ms ))
        step=$((step+1)); total=$((total+mbps))
        printf '        第%s段   %s MB/s   （读 %s MB）\n' "$step" "$mbps" "$this_mb"
    done
    if [ "$step" -eq 0 ]; then
        warn "三段都太小，算不出可信的速度。"
        pause_enter; exit 0
    fi
    avg=$(( total / step ))
    printf '\n'
    if [ "$avg" -ge 1500 ]; then
        warn "读数 ${avg} MB/s —— 这是内存缓存的速度，不是这支盘的真实速度。"
        info "Windows 那份启动器能绕开系统缓存测，要准数请用它。"
    else
        ok "平均顺序读 ${avg} MB/s"
        if [ "$avg" -gt 0 ]; then
            est=$(( MODEL_BYTES / 1048576 / avg + 5 ))
            info "按这个速度，加载这个模型大约要等 ${est} 秒（+5 秒是后端初始化）。"
        fi
        # 这个读数会偏高：dd 走的是系统缓存，文件刚被读过就会命中。
        # 之所以不修，是因为要绕开得自己写 O_DIRECT，为它引一堆代码不值 ——
        # Windows 那份已经用 FILE_FLAG_NO_BUFFERING 给出可信的数了。
        info "注：这个数是走系统缓存的近似值，通常偏高。要看准的用 Windows 那份。"
    fi
    exit 0
fi

# ---- 端口 ----
# 判占用依次退让：lsof 最准；没有就用 nc 探；再没有就用 curl 敲一下 HTTP。
# 三样都没有的机器上判不出来，按"空闲"处理 —— 让引擎自己去撞，总比把用户拦在门口强。
port_busy() {
    if command -v lsof >/dev/null 2>&1; then
        lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
    elif command -v nc >/dev/null 2>&1; then
        nc -z 127.0.0.1 "$1" >/dev/null 2>&1
    elif command -v curl >/dev/null 2>&1; then
        curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$1/" 2>/dev/null
    else
        return 1
    fi
}
if port_busy "$PORT"; then
    # 和 Windows 那份启动器保持一致：被占就往后退，不把用户拦在门口。
    # docs/常见问题.md「端口已被占用」一节写的也是这个行为。
    pf_want="$PORT"; pf_try=""
    pf_n=1
    while [ "$pf_n" -le 20 ]; do
        pf_guess=$((pf_want + pf_n))
        if ! port_busy "$pf_guess"; then pf_try="$pf_guess"; break; fi
        pf_n=$((pf_n + 1))
    done
    if [ -z "$pf_try" ]; then
        err "端口 $pf_want ~ $((pf_want + 20)) 全被占用了，起不来。"
        info "先腾一个出来，或者换一段： bash 启动AI.sh --port 9000"
        pause_enter; exit 1
    fi
    warn "端口 $pf_want 被别的程序占用了，改用 $pf_try。"
    PORT="$pf_try"
fi

# 把最终端口落盘。Windows 那边「高级选项.bat [8] 打开 AI 网页界面」靠这个文件找地址 ——
# 端口被占时启动器会自动换号，菜单那边猜不到，只能由这里写出来。
mkdir -p "$DIR_LOG" 2>/dev/null || true
printf '%s\n' "$PORT" > "$PORT_FILE" 2>/dev/null || true

# ---- 起 ----
URL="http://127.0.0.1:$PORT"
head_line "正在启动  ·  模型加载完就能用"
info "就绪之后：$URL"
info "停掉：这个窗口按 Ctrl-C，或另开窗口跑 bash 启动AI.sh --stop"
printf '\n'

if [ "$OPEN_BROWSER" = 1 ]; then
    (
        # 这个看守是"孤儿候选"：下面的 exec 会把启动器进程整个换成引擎，
        # shell 级的 EXIT trap 随之消失，没有人管得到这个子 shell。
        # 所以它得自己认死 —— 主进程没了就收工。否则引擎崩掉之后，它还可能在
        # 最多 300 秒里把浏览器弹到**别人的**服务上。
        # 用 $$ 而不是 $PPID：子 shell 里 $$ 是主 shell 的 PID，而 exec 保持 PID 不变，
        # 所以 $$ 正好是"启动器/引擎"那个进程。$PPID 指的是启动器的父进程（终端），认错人。
        i=0
        while [ "$i" -lt 300 ]; do
            i=$((i+1))
            sleep 1
            kill -0 "$$" 2>/dev/null || exit 0
            # -f 让 4xx/5xx 也算失败：模型还在加载时 /health 返回 503，
            # 不带 -f 的话那一刻就当成"就绪"，浏览器会开在一个还没准备好的服务上。
            if curl -fsS -o /dev/null --max-time 2 "$URL/health" 2>/dev/null; then
                case "$PLATFORM_OS" in
                    macos) open "$URL" >/dev/null 2>&1 ;;
                    linux) command -v xdg-open >/dev/null 2>&1 && xdg-open "$URL" >/dev/null 2>&1 ;;
                esac
                break
            fi
        done
    ) &
fi

trap 'kill $(jobs -p) 2>/dev/null || true' EXIT INT TERM

# exFAT / FAT32 上没有可执行位，从 Windows 拷进去的引擎挂到 Linux 后常常没有 x。
# 先自己补一次；补不了就说清原因，别让 exec 抛一句干巴巴的 Permission denied。
if [ ! -x "$ENGINE" ]; then
    chmod +x "$ENGINE" 2>/dev/null || true
fi
if [ ! -x "$ENGINE" ]; then
    warn "引擎文件没有执行权限：$ENGINE"
    info "试一下： chmod +x \"$ENGINE\""
    info "如果改不动（盘是只读挂载的），重新挂载时带上 exec 选项再试。"
    exit 1
fi

# 引擎的工作目录 = AI 能看见的世界。参数里的路径都是绝对路径，先切过去不影响它们。
if [ "$TOOLS_ON" = 1 ] && [ -d "$TOOL_DIR" ]; then
    cd "$TOOL_DIR" || true
fi

exec "$ENGINE" "$@"
