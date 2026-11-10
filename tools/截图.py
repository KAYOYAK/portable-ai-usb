"""用 Playwright 截 USB 项目（llama-server Web UI）的展示图。

流程：打开 → 输入问题 → 发送 → 等回复 → 截图

    python _usb_shot.py
"""
import sys
import time
from pathlib import Path

from playwright.sync_api import sync_playwright

URL = "http://127.0.0.1:8080/"
OUT_DIR = Path(__file__).resolve().parent.parent / "docs"

# 展示用的问题：经典 LLM 陷阱题，答对说明真有能力
QUESTIONS = [
    "用 Python 写一个判断回文的函数，忽略大小写和标点。代码后面用两句话说明思路。",
]


def wait_reply(page, timeout_s: int = 180) -> str:
    """等模型回复完成。llama-ui 回复完成后 Send 按钮会恢复可用。"""
    deadline = time.time() + timeout_s
    last = ""
    stable = 0
    while time.time() < deadline:
        page.wait_for_timeout(1000)
        try:
            txt = page.inner_text("body")
        except Exception:
            continue
        if txt == last and len(txt) > 200:
            stable += 1
            # 连续 4 秒没变化，认为生成结束
            if stable >= 4:
                return txt
        else:
            stable = 0
            last = txt
    return last


def run():
    with sync_playwright() as p:
        b = p.chromium.launch(channel="msedge", headless=True)
        page = b.new_page(viewport={"width": 1440, "height": 900},
                          device_scale_factor=2,
                          color_scheme="dark")
        page.goto(URL, wait_until="networkidle", timeout=60000)
        page.wait_for_timeout(2500)

        for q in QUESTIONS:
            print(f"输入: {q}")
            ta = page.query_selector("textarea")
            if not ta:
                print("  ✗ 找不到输入框")
                return 1
            ta.click()
            ta.fill(q)
            page.wait_for_timeout(400)

            # 发送：优先按 Enter
            ta.press("Enter")
            print("  已发送，等回复…")
            t0 = time.time()
            body = wait_reply(page)
            dt = time.time() - t0
            print(f"  回复完成 {dt:.0f}s，body {len(body)} 字符")

            name = "usb-chat.png"
            out = OUT_DIR / name
            page.screenshot(path=str(out), full_page=False, type="png")
            print(f"  ✓ {name}  {out.stat().st_size / 1024:.0f} KB")
            print("\n--- 页面文字 ---")
            print(body[:1200])

        b.close()
    return 0


if __name__ == "__main__":
    sys.exit(run())
