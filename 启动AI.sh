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
  --no-browser         启动后不自动开浏览器
  -h, --help           显示这段帮助

说明：
  · 模型文件（models/*.gguf）在 Windows 和 macOS / Linux 上通用，不用重下
  · 引擎不通用：各平台要有各自的一份，放在 llama.cpp/<平台>/ 下
  · 缺引擎时本脚本会告诉你该下哪一个，不会去网上乱找
HELP
}

while [ $# -gt 0 ]; do
    case "$1" in
        --list)       DO_LIST=1 ;;
        --probe)      DO_PROBE=1 ;;
        --bench)      DO_BENCH=1 ;;
        --stop)       DO_STOP=1 ;;
        --model)      shift; MODEL_NAME="${1:-}" ;;
        --ctx)        shift; CTX="${1:-}" ;;
        --ngl)        shift; NGL="${1:-}" ;;
        --port)       shift; PORT="${1:-}" ;;
        --load-mode)  shift; LOAD_MODE="${1:-}" ;;
        --no-browser) OPEN_BROWSER=0 ;;
        -h|--help)    show_help; exit 0 ;;
        *)            err "不认识的选项：$1"; printf '\n'; show_help; exit 1 ;;
    esac
    shift
done

# ---------------------------------------------------------------- 平台
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
        if [ -x "$DIR_LLAMA/$name/llama-server" ]; then
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
    hits="$(list_models | grep -Fx -- "$want" 2>/dev/null || true)"
    if [ -z "$hits" ]; then
        hits="$(list_models | grep -Fx -- "$want.gguf" 2>/dev/null || true)"
    fi
    if [ -z "$hits" ]; then
        lwant="$(printf '%s' "$want" | tr '[:upper:]' '[:lower:]')"
        hits="$(list_models | while IFS= read -r l; do
                    case "$(printf '%s' "$l" | tr '[:upper:]' '[:lower:]')" in
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
    # 只认"本盘路径"下跑起来的，别的程序起的 llama-server 不碰
    pids="$(pgrep -f "$DIR_LLAMA.*llama-server" 2>/dev/null || true)"
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
    do_stop
    exit 0
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
    want="$(tr -d '\r\n' < "$DIR_MODELS/当前模型.txt")"
    if [ -n "$want" ]; then
        out="$(resolve_model "$want")"; rc=$?
        if [ "$rc" -eq 0 ]; then
            MODEL="$out"; SOURCE="当前模型.txt 指定"
        else
            warn "当前模型.txt 里写的「$want」没法唯一确定，改回自动选最大的。"
        fi
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
MODEL_HUMAN="$(human "$MODEL_BYTES")"

printf '  模型     : %s%s%s  (%s)\n' "$C_OK" "$MODEL_BASE" "$C_OFF" "$SOURCE"
printf '  模型大小 : %s\n' "$MODEL_HUMAN"

# ---- 多模态投影文件 ----
# 和 Windows 那份同一套逻辑：找到就显式指过去，没找到就显式关掉。
# 关掉不是可选项 —— 引擎在「没给投影文件」时存在自己去下的路径，那就要联网，
# 而这个盘的卖点之一就是首次启动完全离线。
MMPROJ=""
if [ -d "$DIR_MODELS" ]; then
    MMPROJ="$(find "$DIR_MODELS" -maxdepth 1 -name 'mmproj-*.gguf' -type f 2>/dev/null | head -1)"
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

# ---- 拼参数 ----
set -- \
    -m "$MODEL" \
    --alias "$MODEL_ALIAS" \
    --host 127.0.0.1 \
    --port "$PORT" \
    --n-gpu-layers "$NGL" \
    --ctx-size "$CTX" \
    --threads "$THREADS" \
    --jinja \
    --reasoning-format deepseek \
    --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0

# 只有 vulkan/cuda 那两份引擎才有这两个开关；macOS 的 Metal 交给引擎自己定
case "$ENGINE" in
    *vulkan*|*cuda*) set -- "$@" --flash-attn on --cache-type-k "$KV_TYPE" --cache-type-v "$KV_TYPE" ;;
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

printf '\n'
printf '  %s上下文   : %s tokens%s\n' "$C_DIM" "$CTX" "$C_OFF"
printf '  显存卸载 : %s 层\n' "$NGL"
printf '  KV 缓存  : %s\n' "$KV_TYPE"
printf '  CPU 线程 : %s  (本机 %s 核)\n' "$THREADS" "$CPU_CORES"
printf '  内存     : %s GB\n' "$RAM_GB"
[ "$LOAD_MODE" != "auto" ] && printf '  加载方式 : %s %s\n' "$LOAD_MODE" "$LOAD_NOTE"

if [ "$DO_PROBE" = 1 ]; then
    head_line "探测完成（没有真的启动引擎）"
    printf '  模型  = %s\n' "$MODEL_BASE"
    printf '  ctx   = %s        ngl = %s        kv = %s\n' "$CTX" "$NGL" "$KV_TYPE"
    printf '  内存  = %s GB     线程 = %s\n' "$RAM_GB" "$THREADS"
    exit 0
fi

# ---- 测速 ----
# 说明：这里测的是「接近真实」的顺序读，不声称绕过了系统缓存 ——
# 真要绕过得自己写 O_DIRECT，为它引一堆代码不值得。缓存命中时会明确说出来。
if [ "$DO_BENCH" = 1 ]; then
    step=0
    total=0
    printf '\n  正在读 3 段，每段 32 MB……\n'
    for frac in 20 55 80; do
        skip_mb=$(( MODEL_BYTES / 1048576 * frac / 100 ))
        t0="$(now_ms)"
        dd if="$MODEL" of=/dev/null bs=1048576 count=32 skip="$skip_mb" 2>/dev/null || true
        t1="$(now_ms)"
        ms=$(( t1 - t0 ))
        [ "$ms" -gt 0 ] || ms=1
        mbps=$(( 32 * 1000 / ms ))
        step=$((step+1)); total=$((total+mbps))
        printf '        第%s段   %s MB/s\n' "$step" "$mbps"
    done
    avg=$(( total / 3 ))
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
port_busy() {
    if command -v lsof >/dev/null 2>&1; then
        lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
    else
        return 1
    fi
}
if port_busy "$PORT"; then
    err "端口 $PORT 已经被占用了"
    info "换一个： bash 启动AI.sh --port 8081"
    info "或先停掉占着的： bash 启动AI.sh --stop"
    pause_enter; exit 1
fi

# ---- 起 ----
URL="http://127.0.0.1:$PORT"
head_line "正在启动  ·  模型加载完就能用"
info "就绪之后：$URL"
info "停掉：这个窗口按 Ctrl-C，或另开窗口跑 bash 启动AI.sh --stop"
printf '\n'

if [ "$OPEN_BROWSER" = 1 ]; then
    (
        i=0
        while [ "$i" -lt 300 ]; do
            i=$((i+1))
            sleep 1
            if curl -s -o /dev/null --max-time 2 "$URL/health" 2>/dev/null; then
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
exec "$ENGINE" "$@"
