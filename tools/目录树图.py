"""生成「U 盘里有什么」的结构图。

用 Qt 渲染纯文本树 —— 不启动任何引擎，不占显存。
重点是让人一眼看懂「模型 + 引擎 + 脚本全在盘里」。
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from PySide6.QtCore import Qt
from PySide6.QtGui import QColor, QFont, QImage, QPainter
from PySide6.QtWidgets import QApplication

app = QApplication(sys.argv)

C_BG = "#181818"
C_TXT = "#f4f4f5"
C_DIM = "#86868b"
C_ACCENT = "#ff6a2b"
C_OK = "#7dd6a0"

W, H = 1100, 760
PAD = 44

# (缩进层级, 名称, 颜色, 右边注释)
LINES = [
    (0, "D:\\portable-ai-usb\\", C_TXT, ""),
    (1, "启动AI.bat", C_ACCENT, "← 双击这个"),
    (1, "高级选项.bat", C_DIM, "换模型 / 省显存 / 自检"),
    (1, "launcher.ps1", C_DIM, "114 KB，全部逻辑"),
    (1, "models\\", C_OK, ""),
    (2, "MiMo-V2.6-Distill-Qwen-9B-Q5_K_M.gguf", C_TXT, "6.02 GB"),
    (2, "mmproj-...-f16.gguf", C_TXT, "0.86 GB  视觉投影"),
    (1, "llama.cpp\\", C_OK, ""),
    (2, "cuda13\\llama-server.exe", C_TXT, "NVIDIA 显卡"),
    (2, "vulkan\\llama-server.exe", C_DIM, "AMD / Intel"),
    (2, "cpu\\llama-server.exe", C_DIM, "任何机器兜底"),
    (1, "templates\\", C_DIM, "聊天模板"),
    (1, "tools\\", C_OK, ""),
    (2, "自检.ps1", C_DIM, "U 盘文件是否齐全"),
    (2, "换模型.ps1", C_DIM, "从镜像下别的模型"),
    (2, "文档识别.ps1", C_DIM, "OCR"),
    (2, "准备U盘.ps1", C_DIM, "自动组装这支盘"),
    (1, "docs\\", C_DIM, "踩坑记录 / 常见问题"),
    (1, "logs\\", C_DIM, "对话记录 / 备份"),
]

img = QImage(W, H, QImage.Format_ARGB32)
img.fill(QColor(C_BG))
p = QPainter(img)
p.setRenderHint(QPainter.Antialiasing)
p.setRenderHint(QPainter.TextAntialiasing)

# 标题
p.setPen(QColor(C_TXT))
p.setFont(QFont("Microsoft YaHei UI", 15, QFont.Bold))
p.drawText(PAD, 58, "U 盘里有什么")

p.setPen(QColor(C_DIM))
p.setFont(QFont("Microsoft YaHei UI", 9))
p.drawText(PAD, 84, "模型 / 推理引擎 / 运行库 / 启动脚本 —— 全在盘里，插上就能用")

# 树
mono = QFont("Consolas", 11)
mono.setStyleHint(QFont.Monospace)
p.setFont(mono)

y = 130
indent = 26
line_h = 30
for level, name, color, note in LINES:
    x = PAD + level * indent
    # 目录前缀
    prefix = ""
    if level > 0:
        prefix = "├─ " if name.endswith("\\") else "├─ "
    p.setPen(QColor(color))
    label = prefix + name
    p.drawText(x, y, label)

    if note:
        p.setPen(QColor(C_DIM))
        p.setFont(QFont("Microsoft YaHei UI", 9))
        # 右对齐注释
        fm = p.fontMetrics()
        nw = fm.horizontalAdvance(note)
        p.drawText(W - PAD - nw, y, note)
        p.setFont(mono)
    y += line_h

# 底部说明
p.setPen(QColor(C_DIM))
p.setFont(QFont("Microsoft YaHei UI", 9))
p.drawText(PAD, H - 34, "约 7.0 GB。拷贝时间取决于写入速度；读取实测 1069.6 MB/s，加载模型约 11 秒。")

p.end()
out = ROOT / "docs" / "usb-tree.png"
img.save(str(out))
print(f"✓ {out.name}  {img.width()}x{img.height()}  {out.stat().st_size / 1024:.0f} KB")
