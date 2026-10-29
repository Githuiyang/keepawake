#!/usr/bin/env python3
"""生成 KeepAwake 宣传素材（像素级复刻 UI）。

输出到 docs/：
  usage-off.png   使用截图·休眠态（浅色桌面 + 菜单栏 + 刘海 + 卡片）
  usage-on.png    使用截图·运行态
  promo-card.png  宣传主卡 1080x1350（发帖用）

配色 = KeepAwake.swift ConsolePalette。
"""
from __future__ import annotations

from pathlib import Path

import qrcode
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent
DOCS = ROOT / "docs"
DOCS.mkdir(exist_ok=True)

# ---- ConsolePalette ----
CREAM = (250, 249, 245)
WARM_GRAY = (168, 165, 160)
ACCENT = (217, 119, 87)
CARD_BG = (38, 38, 36)
HAIRLINE = (255, 255, 255, 23)
DOT_DIM = (107, 105, 97)

SONGTI = "/System/Library/Fonts/Supplemental/Songti.ttc"
HIRAGINO = "/System/Library/Fonts/Hiragino Sans GB.ttc"
MENLO = "/System/Library/Fonts/Menlo.ttc"


def load_font(path: str, size: int, want: str = "Regular") -> ImageFont.FreeTypeFont:
    """在 ttc 里找 SC 字重的字体，找不到就退回第 0 个。"""
    for idx in range(8):
        try:
            f = ImageFont.truetype(path, size, index=idx)
            name = f.getname()
            joined = " ".join(name)
            if "SC" in joined and want in joined:
                return f
        except Exception:
            break
    for idx in range(8):
        try:
            f = ImageFont.truetype(path, size, index=idx)
            if want in " ".join(f.getname()):
                return f
        except Exception:
            break
    return ImageFont.truetype(path, size, index=0)


def v_gradient(size, top, bottom):
    w, h = size
    img = Image.new("RGB", size)
    d = ImageDraw.Draw(img)
    for y in range(h):
        t = y / max(1, h - 1)
        c = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
        d.line([(0, y), (w, y)], fill=c)
    return img


def draw_card(layer, xy, scale, is_on, with_glow=True):
    """画迷你控制台卡片（真实 176x24 的 scale 倍）。"""
    W, H = int(176 * scale), int(24 * scale)
    x, y = xy
    r = int(7 * scale)

    # 阴影 + 光晕（在独立层画完贴回）
    if with_glow:
        sh = Image.new("RGBA", (W + 80, H + 80), (0, 0, 0, 0))
        sd = ImageDraw.Draw(sh)
        sd.rounded_rectangle([40, 44, 40 + W, 44 + H], r, fill=(0, 0, 0, 90))
        sh = sh.filter(ImageFilter.GaussianBlur(10))
        if is_on:
            gl = Image.new("RGBA", sh.size, (0, 0, 0, 0))
            gd = ImageDraw.Draw(gl)
            gd.rounded_rectangle([40, 42, 40 + W, 42 + H], r, fill=ACCENT + (70,))
            gl = gl.filter(ImageFilter.GaussianBlur(14))
            sh = Image.alpha_composite(sh, gl)
        layer.paste(Image.alpha_composite(layer.crop((x - 40, y - 40, x - 40 + sh.width, y - 40 + sh.height)), sh),
                    (x - 40, y - 40))

    d = ImageDraw.Draw(layer)
    d.rounded_rectangle([x, y, x + W, y + H], r, fill=CARD_BG + (238,))
    border = tuple(int(c * 0.28 + 255 * 0) for c in ACCENT) + (71,) if is_on else HAIRLINE
    if is_on:
        border = (ACCENT[0], ACCENT[1], ACCENT[2], 71)
    d.rounded_rectangle([x, y, x + W, y + H], r, outline=border, width=max(1, scale // 2))

    pad = int(10 * scale)
    dot_r = int(2.5 * scale)
    cy = y + H // 2
    d.ellipse([x + pad, cy - dot_r, x + pad + 2 * dot_r, cy + dot_r],
              fill=ACCENT if is_on else DOT_DIM)

    title_f = load_font(SONGTI, int(11 * scale), "Bold")
    title = "合盖运行中" if is_on else "合盖休眠"
    tx = x + pad + 2 * dot_r + int(8 * scale)
    d.text((tx, cy), title, font=title_f, fill=CREAM, anchor="lm")

    badge_f = load_font(MENLO, int(10 * scale), "Bold")
    badge = "O N" if is_on else "O F F"
    bw = d.textlength(badge, font=badge_f)
    d.text((x + W - pad - bw, cy), badge, font=badge_f,
           fill=ACCENT if is_on else tuple(int(c * 0.7) for c in WARM_GRAY), anchor="lm")


def draw_cursor(layer, x, y, s=1.0):
    """macOS 白色箭头光标。"""
    pts = [(0, 0), (0, 17), (4.4, 13.2), (7.6, 19.6), (10.2, 18.3), (7.1, 12.1), (12.6, 12.0)]
    pts = [(x + px * s, y + py * s) for px, py in pts]
    d = ImageDraw.Draw(layer)
    d.polygon(pts, fill=(255, 255, 255, 240), outline=(40, 40, 40, 200))


def usage_screenshot(is_on: bool, out: Path):
    W, H = 1600, 1000
    img = v_gradient((W, H), (240, 237, 231), (216, 211, 202)).convert("RGBA")
    # 桌面氛围：几个柔和色块
    soft = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    sd = ImageDraw.Draw(soft)
    sd.ellipse([950, 520, 1650, 1050], fill=(226, 172, 140, 44))
    sd.ellipse([-200, 300, 420, 900], fill=(150, 168, 158, 40))
    soft = soft.filter(ImageFilter.GaussianBlur(60))
    img = Image.alpha_composite(img, soft)

    d = ImageDraw.Draw(img)
    # 菜单栏
    d.rectangle([0, 0, W, 36], fill=(246, 244, 240, 226))
    menu_f = load_font(HIRAGINO, 14, "Regular")
    d.text((20, 18), "Finder", font=menu_f, fill=(60, 58, 54), anchor="lm")
    x = 78
    for item in ["文件", "编辑", "显示", "前往", "窗口", "帮助"]:
        d.text((x, 18), item, font=menu_f, fill=(60, 58, 54), anchor="lm")
        x += d.textlength(item, font=menu_f) + 22
    # 右侧状态图标（手绘近似）
    d.text((W - 24, 18), "周四 20:45", font=menu_f, fill=(60, 58, 54), anchor="rm")
    # 控制中心（两个小胶囊）
    ccx = W - 130
    d.rounded_rectangle([ccx, 10, ccx + 8, 18], 4, outline=(60, 58, 54), width=1)
    d.rounded_rectangle([ccx + 11, 10, ccx + 19, 18], 4, outline=(60, 58, 54), width=1)
    # wifi 弧线
    wx = W - 172
    for i, r in enumerate([4, 7, 10]):
        d.arc([wx - r, 18 - r - 1, wx + r, 18 + r - 1], 215, 325, fill=(60, 58, 54), width=2)
    d.ellipse([wx - 1.5, 15, wx + 1.5, 18], fill=(60, 58, 54))
    # 电池
    bx = W - 224
    d.rounded_rectangle([bx, 11, bx + 24, 25], 3, outline=(60, 58, 54), width=1)
    d.rectangle([bx + 25, 15, bx + 27, 21], fill=(60, 58, 54))
    d.rounded_rectangle([bx + 2, 13, bx + 19, 23], 2, fill=(60, 58, 54))

    # 刘海
    d.rounded_rectangle([W // 2 - 105, 0, W // 2 + 105, 36], 12,
                        fill=(10, 10, 10, 255), corners=(False, False, True, True))

    # 卡片（真实 176x24 → 2 倍）居中于刘海正下方
    draw_card(img, (W // 2 - 176, 92), 2, is_on)
    draw_cursor(img, W // 2 - 220, 104, 1.7)

    img.convert("RGB").save(out, "PNG")
    print(f"已生成 {out}")


def promo_card(out: Path):
    W, H = 1080, 1350
    img = v_gradient((W, H), (36, 35, 33), (19, 18, 17)).convert("RGBA")
    # 底部橙色氛围光
    glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse([W // 2 - 420, H - 620, W // 2 + 420, H + 220], fill=ACCENT + (46,))
    glow = glow.filter(ImageFilter.GaussianBlur(130))
    img = Image.alpha_composite(img, glow)

    d = ImageDraw.Draw(img)
    d.rectangle([26, 26, W - 26, H - 26], outline=(255, 255, 255, 20), width=1)

    mono_s = load_font(MENLO, 20, "Regular")
    d.text((W // 2, 108), "O P E N   S O U R C E   ·   M A C O S   1 3 +   ·   M I T",
           font=mono_s, fill=WARM_GRAY, anchor="mm")

    title_f = load_font(SONGTI, 118, "Bold")
    d.text((W // 2, 248), "KeepAwake", font=title_f, fill=CREAM, anchor="mm")

    tag_f = load_font(SONGTI, 42, "Bold")
    d.text((W // 2, 356), "合上盖子——睡，还是不睡？", font=tag_f, fill=CREAM, anchor="mm")
    sub_f = load_font(HIRAGINO, 26, "Regular")
    d.text((W // 2, 412), "刘海之下的一颗开关", font=sub_f, fill=WARM_GRAY, anchor="mm")

    # 双状态卡片
    draw_card(img, (W // 2 - 141, 508), 1.6, False)
    draw_card(img, (W // 2 - 141, 612), 1.6, True)
    swap_f = load_font(MENLO, 18, "Regular")
    d.text((W // 2 + 160, 580), "↑ 点击切换 ↓", font=swap_f, fill=WARM_GRAY, anchor="lm")

    # 特性
    feat_f = load_font(HIRAGINO, 29, "Medium")
    feats = [
        "平时隐形 · 鼠标移到刘海即现",
        "一键切换 合盖休眠 / 合盖运行（可免密）",
        "防改回守卫 · 外部篡改 5 秒自愈",
        "单文件 Swift · Apple Silicon + Intel",
    ]
    y = 780
    for line in feats:
        d.ellipse([130, y - 6, 142, y + 6], fill=ACCENT)
        d.text((166, y), line, font=feat_f, fill=(232, 229, 223), anchor="lm")
        y += 66

    # 底部：GitHub + 二维码
    d.line([80, 1120, W - 80, 1120], fill=(255, 255, 255, 26), width=1)
    gh_s = load_font(MENLO, 21, "Regular")
    gh_f = load_font(MENLO, 28, "Bold")
    d.text((100, 1180), "G i t H u b", font=gh_s, fill=WARM_GRAY, anchor="lm")
    d.text((100, 1226), "github.com/Githuiyang/keepawake", font=gh_f, fill=CREAM, anchor="lm")

    qr = qrcode.QRCode(border=1, box_size=8,
                       error_correction=qrcode.constants.ERROR_CORRECT_M)
    qr.add_data("https://github.com/Githuiyang/keepawake")
    qr.make(fit=True)
    qimg = qr.make_image(fill_color=(31, 30, 29), back_color="white").convert("RGB")
    qimg = qimg.resize((168, 168))
    qcard = Image.new("RGBA", (192, 192), (255, 255, 255, 255))
    qcard.paste(qimg, (12, 12))
    d2 = ImageDraw.Draw(qcard)
    img.paste(qcard, (W - 292, 1168), qcard)

    img.convert("RGB").save(out, "PNG")
    print(f"已生成 {out}")


if __name__ == "__main__":
    usage_screenshot(False, DOCS / "usage-off.png")
    usage_screenshot(True, DOCS / "usage-on.png")
    promo_card(DOCS / "promo-card.png")
