"""录 USB 项目演示：多帧截图 + 合成 GIF/MP4。

不用 Playwright 内置录制（它要单独下载 ffmpeg），改成自己抓帧再合成，
这样也方便控制帧率和尺寸。

    python _usb_record.py
"""
import sys
import shutil
import time
from pathlib import Path

from playwright.sync_api import sync_playwright

URL = "http://127.0.0.1:8080/"
ROOT = Path(__file__).resolve().parent.parent
FRAMES = ROOT / "_usb_frames"
OUT_GIF = ROOT / "docs" / "usb-demo.gif"
OUT_MP4 = ROOT / "docs" / "usb-demo.mp4"

W, H = 1280, 800
FPS = 10

QUESTION = "用 Python 写一个判断回文的函数，忽略大小写和标点。"

frames: list = []


def grab(page):
    try:
        png = page.screenshot(type="png")
        frames.append(png)
    except Exception:
        pass


def main() -> int:
    if FRAMES.exists():
        shutil.rmtree(FRAMES)
    FRAMES.mkdir(parents=True)

    with sync_playwright() as p:
        browser = p.chromium.launch(channel="msedge", headless=True)
        ctx = browser.new_context(
            viewport={"width": W, "height": H},
            device_scale_factor=1,
            color_scheme="dark",
        )
        page = ctx.new_page()
        page.goto(URL, wait_until="networkidle", timeout=60000)
        page.wait_for_timeout(2500)

        # 空界面停留
        for _ in range(6):
            grab(page)
        page.wait_for_timeout(200)

        ta = page.query_selector("textarea")
        if not ta:
            print("找不到输入框", file=sys.stderr)
            return 1
        ta.click()

        # 逐字输入，每 2 字抓一帧
        print("逐字输入…")
        for i, ch in enumerate(QUESTION):
            ta.type(ch, delay=0)
            if i % 2 == 0:
                grab(page)
            page.wait_for_timeout(60)
        for _ in range(4):
            grab(page)

        print("发送…")
        ta.press("Enter")

        # 流式回复：每 500ms 抓一帧，直到稳定
        print("等回复…")
        deadline = time.time() + 240
        last, stable = "", 0
        while time.time() < deadline:
            grab(page)
            page.wait_for_timeout(400)
            try:
                txt = page.inner_text("body")
            except Exception:
                continue
            if txt == last and len(txt) > 300:
                stable += 1
                if stable >= 6:
                    break
            else:
                stable = 0
                last = txt

        print(f"  回复完成，body {len(last)} 字符，共 {len(frames)} 帧")
        # 结尾停留
        for _ in range(10):
            grab(page)
            page.wait_for_timeout(150)

        ctx.close()
        browser.close()

    if not frames:
        print("没抓到帧", file=sys.stderr)
        return 1

    # 写盘 → PIL → 合成
    from PIL import Image
    import io
    import numpy as np
    import imageio.v2 as iio

    pils = [Image.open(io.BytesIO(b)).convert("RGB") for b in frames]
    print(f"转成 PIL {len(pils)} 帧")

    # GIF（缩小到 960 宽，128 色）
    gw = 960
    gh = int(gw * H / W)
    small = [p.resize((gw, gh), Image.LANCZOS) for p in pils]
    quant = [p.convert("P", palette=Image.ADAPTIVE, colors=128) for p in small]
    quant[0].save(str(OUT_GIF), save_all=True, append_images=quant[1:],
                  duration=int(1000 / FPS), loop=0, optimize=True, disposal=2)
    print(f"  ✓ {OUT_GIF.name}  {OUT_GIF.stat().st_size / 1024:.0f} KB")

    # MP4（原尺寸 20fps）
    writer = iio.get_writer(str(OUT_MP4), fps=20, codec="libx264",
                            quality=8, pixelformat="yuv420p",
                            macro_block_size=1)
    for p in pils:
        arr = np.asarray(p)
        writer.append_data(arr)
        writer.append_data(arr)
    writer.close()
    print(f"  ✓ {OUT_MP4.name}  {OUT_MP4.stat().st_size / 1024:.0f} KB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
