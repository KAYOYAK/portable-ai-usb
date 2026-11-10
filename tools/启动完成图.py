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

# 进度条那一行：\r 被写成了空格串，把它拆成多行方便阅读
lines_out: list[str] = []
for line in raw.splitlines():
    # 进度条行特征：包含 "##...] " 和 "s / 约"
    if "] " in line and "s / 约" in line and line.count("[") >= 3:
        # 用 "  [" 切分
        parts = re.split(r"\s{2,}(?=\[)", line.strip())
        for p in parts:
            p = p.strip()
            if p:
                lines_out.append("  " + p)
    else:
        lines_out.append(line.rstrip())

# 去掉开头连续空行
while lines_out and not lines_out[0].strip():
    lines_out.pop(0)

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
H = TOP + len(lines_out) * LINE_H + BOTTOM

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
