#!/usr/bin/env python3
"""生成 VoiceKey 的 App 图标（1024×1024，不透明）。

用法：
    pip install pillow numpy
    python3 tools/make_icon.py            # 写入 VoiceKey/Assets.xcassets/AppIcon.appiconset/AppIcon1024.png
    python3 tools/make_icon.py --preview  # 额外输出 180px / 60px 预览到 /tmp 供肉眼检查

设计：近黑底 + 克制的靛蓝辉光；白色波形，最右收成一根细竖条（"语音 → 光标"的意象）。
4 倍超采样后 Lanczos 降采样，保证小尺寸下边缘干净；输出 RGB（无 alpha），符合 App Store 要求。
"""
import argparse
import os

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "VoiceKey/Assets.xcassets/AppIcon.appiconset/AppIcon1024.png")

SIZE = 4096          # 超采样画布
GLOW_COLOR = (0.36, 0.38, 0.92)


def build() -> Image.Image:
    yy, xx = np.mgrid[0:SIZE, 0:SIZE].astype(np.float32)
    cx, cy = SIZE * 0.5, SIZE * 0.50
    dist = np.sqrt((xx - cx) ** 2 + (yy - cy) ** 2) / (SIZE * 0.58)
    glow = np.clip(1.0 - dist, 0.0, 1.0) ** 2.0

    base = np.zeros((SIZE, SIZE, 3), np.float32)
    base[..., 0], base[..., 1], base[..., 2] = 0.043, 0.043, 0.055
    base = base + glow[..., None] * np.array(GLOW_COLOR, np.float32) * 0.28
    base = base + np.linspace(0.0, 1.0, SIZE, dtype=np.float32)[:, None, None] * 0.032

    img = Image.fromarray((np.clip(base, 0, 1) * 255).astype(np.uint8), "RGB").convert("RGBA")
    draw = ImageDraw.Draw(img)

    def px(v: float) -> float:
        return v * SIZE / 1024.0

    white = (255, 255, 255, 255)
    bar_w = px(62)
    gap = px(40)
    caret_gap = px(78)
    heights = [0.34, 0.68, 1.00, 0.60, 0.38]
    max_h = px(520)

    total = len(heights) * bar_w + (len(heights) - 1) * gap + caret_gap + bar_w * 0.58
    x = (SIZE - total) / 2
    center_y = SIZE * 0.50
    for h in heights:
        bh = max_h * h
        y0 = center_y - bh / 2
        draw.rounded_rectangle([x, y0, x + bar_w, y0 + bh], radius=bar_w / 2, fill=white)
        x += bar_w + gap

    caret_w, caret_h = bar_w * 0.58, max_h * 0.50
    x += caret_gap - gap
    draw.rounded_rectangle([x, center_y - caret_h / 2, x + caret_w, center_y + caret_h / 2],
                           radius=caret_w / 2, fill=white)

    glow_layer = img.filter(ImageFilter.GaussianBlur(px(20)))
    img = Image.alpha_composite(glow_layer.point(lambda v: int(v * 0.26)), img)
    return img.resize((1024, 1024), Image.LANCZOS).convert("RGB")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--preview", action="store_true", help="额外输出小尺寸预览到 /tmp")
    ap.add_argument("--out", default=OUT)
    args = ap.parse_args()

    icon = build()
    icon.save(args.out, optimize=True)
    print(f"written {args.out} ({icon.size[0]}x{icon.size[1]}, {icon.mode})")
    if args.preview:
        for size in (180, 60):
            path = f"/tmp/icon-preview-{size}.png"
            icon.resize((size, size), Image.LANCZOS).save(path)
            print("preview", path)


if __name__ == "__main__":
    main()
