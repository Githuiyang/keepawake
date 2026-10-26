#!/usr/bin/env python3
"""生成 KeepAwake 应用图标（iconset → iconutil 用）。

设计：暖调深灰圆角方底 + 品牌橙月牙 + 一颗小星，
延续灵动岛卡片的 Anthropic 风格视觉。
"""
from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image, ImageDraw

# 配色（与 KeepAwake.swift 的 ConsolePalette 一致）
BG_TOP = (43, 42, 40, 255)      # #2B2A28
BG_BOTTOM = (26, 25, 24, 255)   # #1A1918
ACCENT = (217, 119, 87, 255)    # #D97757 品牌橙
STAR = (244, 223, 158, 255)     # 淡金
BORDER = (255, 255, 255, 26)    # 10% 白描边


def rounded_mask(size: int, radius: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(mask)
    d.rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    return mask


def draw_icon(size: int) -> Image.Image:
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    s = size / 512.0  # 以 512 为基准的比例因子

    # 垂直渐变底（两层叠加近似）
    grad = Image.new("RGBA", (size, size))
    top = Image.new("RGBA", (size, size), BG_TOP)
    bottom = Image.new("RGBA", (size, size), BG_BOTTOM)
    grad = Image.blend(top, bottom, 0.55)
    mask = rounded_mask(size, radius=int(118 * s))  # macOS 风格圆角
    img.paste(grad, (0, 0), mask)

    # 细描边
    overlay = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(overlay)
    d.rounded_rectangle(
        [int(1 * s), int(1 * s), size - 1 - int(1 * s), size - 1 - int(1 * s)],
        radius=int(117 * s), outline=BORDER, width=max(1, int(2 * s)),
    )

    # 月牙：橙色圆 + 用背景色圆偏移遮挡
    cx, cy = size * 0.47, size * 0.5
    r = size * 0.26
    d.ellipse(
        [cx - r, cy - r, cx + r, cy + r],
        fill=ACCENT,
    )
    # 遮挡圆（往右上偏移），颜色取该处渐变近似值
    ocx, ocy, orad = cx + r * 0.62, cy - r * 0.30, r * 0.92
    cover = (33, 32, 31, 255)
    d.ellipse(
        [ocx - orad, ocy - orad, ocx + orad, ocy + orad],
        fill=cover,
    )

    # 小星（月牙右上方一点）
    star_cx, star_cy, star_r = size * 0.655, size * 0.335, size * 0.035
    d.ellipse(
        [star_cx - star_r, star_cy - star_r, star_cx + star_r, star_cy + star_r],
        fill=STAR,
    )

    # 把描边/图形都裁回圆角内
    overlay.putalpha(Image.composite(overlay.getchannel("A"), Image.new("L", (size, size), 0), mask))
    img = Image.alpha_composite(img, overlay)
    return img


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--iconset", required=True, help="输出 iconset 目录")
    args = parser.parse_args()

    iconset = Path(args.iconset)
    iconset.mkdir(parents=True, exist_ok=True)

    sizes = [16, 32, 64, 128, 256, 512]
    for sz in sizes:
        draw_icon(sz).save(iconset / f"icon_{sz}x{sz}.png")
        draw_icon(sz * 2).save(iconset / f"icon_{sz}x{sz}@2x.png")
    print(f"iconset 已生成: {iconset}")


if __name__ == "__main__":
    main()
