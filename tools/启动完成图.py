"""把 launcher 的真实输出渲染成终端风格图。

数据来源：_launcher_out.txt（真跑 launcher.ps1 -NoBrowser 捕获的 stdout）
比截控制台窗口可靠得多 —— 窗口会被进度条的 \\r 刷新搞乱，
而 stdout 是逐行的、完整的。
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from PySide6.QtGui import QColor, QFont, QImage, QPainter
from PySide6.QtWidgets import QApplication

app = QApplication(sys.argv)

SRC = Path(__file__).resolve().parent.parent / "docs" / "启动输出.txt"
raw = SRC.read_text(encoding="utf-8", errors="replace")

# 进度条那行要**整行丢掉**，不能拆开展示。
#
# 原因：launcher 的进度条用 Write-Host -NoNewline + \r 原地刷新，
# 重定向到文件时 \r 全部丢失（实测 raw.count(chr(13)) == 0），
# 所有帧被压成一行。而且这一行里的帧本身就不连续 ——
#   1s → 2s → 2s → 5s → 6s → 7s → 7s → 8s →（跳到）AI 已就绪
# 2s 重复、2s→5s 跳跃、8s 之后缺了 9~17s。把它渲染出来会让人以为
# 进度条坏了（实际是捕获问题，不是产品问题）。
#
# 进度条已经单独有 docs/usb-loading.png（真实截图），这里不重复放。
PROGRESS_MARKS = (
    "s / 约",
    "正在读模型文件",
    "正在把模型读进内存",
    # "加载 6.02 GB 模型，实测本盘预计约 11 秒" —— 这个 11 秒是按开发机
    # SSD 的顺序读算的。真 U 盘（SanDisk USB 3.2 Gen1，127~146 MB/s）
    # 要 50 秒以上，留着会让读者对启动速度产生错误预期。
    "实测本盘预计约",
    # 我自己加的说明，不该混进"产品真实输出"的语境里
    "进度条略",
)
lines_out: list[str] = []
dropped_progress = False
for line in raw.splitlines():
    if any(m in line for m in PROGRESS_MARKS):
        dropped_progress = True
        continue
    # 「这次对话已存到 xxx-220609.txt」是**上一次**对话的存档时间，
    # 和本次启动的日志时间（220758）差两分钟。放在启动流程里容易被
    # 误读成矛盾，而且它属于对话存档功能、不属于启动过程，去掉。
    if "这次对话已存到" in line:
        continue
    lines_out.append(line.rstrip())

# 「这支 U 盘：顺序读 1,059 MB/s」这一段必须去掉。
#
# 它测的是**启动器当前所在的那个盘**。README 配图是在开发机的 D: 盘
# （YMTC NVMe SSD）上跑的，所以报出 1000+ MB/s —— 但真 U 盘是
# SanDisk USB 3.2 Gen1，实测只有 127~146 MB/s（见 docs/硬件与性能.md）。
#
# 把 SSD 的数字标成「这支 U 盘」，懂行的人一眼看出是假的。
# 而且这一段会连带「预计加载 11 秒」，和真 U 盘 50+ 秒也对不上。
# 推理速度（token/秒）和介质无关，那个保留。
MEDIA_MARKS = ("这支 U 盘", "顺序读", "随机 4K", "绕过系统缓存", "预计加载")
lines_out = [ln for ln in lines_out if not any(m in ln for m in MEDIA_MARKS)]

# 不要在输出里塞任何注解 —— 这张图要看起来就是终端里真实打出来的样子。
# 进度条已单独有 docs/usb-loading.png，这里直接留空。

# 去掉开头和结尾的连续空行（尾部空行会让图底部留一大块黑）
while lines_out and not lines_out[0].strip():
    lines_out.pop(0)
while lines_out and not lines_out[-1].strip():
    lines_out.pop()

print(f"输出 {len(lines_out)} 行")

C_BG = "#0b1220"
C_TXT = "#c9d1d9"
C_DIM = "#6e7681"
C_OK = "#7ee787"
C_WARN = "#e3b341"
C_CYAN = "#79c0ff"
C_HEAD = "#58a6ff"

W = 1180
LINE_H = 20
TOP = 56
BOTTOM = 40
# 空行只画 LINE_H // 2，按整行预留会在图底部堆出一大块黑。
H = TOP + sum(LINE_H if ln.strip() else LINE_H // 2 for ln in lines_out) + BOTTOM

img = QImage(W, H, QImage.Format_ARGB32)
img.fill(QColor(C_BG))
p = QPainter(img)
p.setRenderHint(QPainter.TextAntialiasing)

# 标题栏
p.fillRect(0, 0, W, 34, QColor("#161b22"))
p.setPen(QColor(C_DIM))
p.setFont(QFont("Microsoft YaHei UI", 9))
p.drawText(14, 22, "启动AI.bat")

mono = QFont("Consolas", 10)
mono.setStyleHint(QFont.Monospace)
p.setFont(mono)

y = TOP
for ln in lines_out:
    if not ln.strip():
        y += LINE_H // 2
        continue
    if re.match(r"^=+\s*$", ln.strip()):
        color = C_DIM
    elif "AI 已就绪" in ln or ln.strip().startswith("AI 已就绪"):
        color = C_OK
    elif "已就绪" in ln or "很快" in ln or "[OK]" in ln:
        color = C_OK
    elif "实测速度" in ln or "tokens" in ln or "token/秒" in ln:
        color = C_CYAN
    elif "有新版本" in ln:
        color = C_WARN
    elif ln.strip().startswith("[#") or ln.strip().startswith("[."):
        color = C_OK
    elif "后端:" in ln or "上下文:" in ln:
        color = C_TXT
    elif ln.strip().startswith("这支 U 盘") or ln.strip().startswith("顺序读"):
        color = C_CYAN
    elif ln.strip().startswith("预计加载"):
        color = C_DIM
    else:
        color = C_TXT
    p.setPen(QColor(color))
    p.drawText(14, y, ln[:150])
    y += LINE_H

p.end()
out = ROOT / "docs" / "usb-ready.png"
img.save(str(out))
print(f"✓ {out.name}  {img.width()}x{img.height()}  {out.stat().st_size / 1024:.0f} KB")
