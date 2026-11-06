#!/usr/bin/env python3
"""Put simulator/emulator captures into device frames and compose the README/website hero.

Needs Pillow (python3 -m venv /tmp/venv && /tmp/venv/bin/pip install pillow). Run from the repo root:

    /tmp/venv/bin/python scripts/frame_screenshots.py <captures-dir> docs/screenshots

<captures-dir> holds ios_en.png, ios_es.png, and_en.png and and_es.png taken with sample data only.
"""
import sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

SS = 3  # supersampling for smooth edges


def rounded_mask(size, radius):
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size[0] - 1, size[1] - 1), radius, fill=255)
    return mask


def gradient(size, top, bottom):
    base = Image.new("RGBA", size)
    px = base.load()
    for y in range(size[1]):
        t = y / max(1, size[1] - 1)
        color = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)) + (255,)
        for x in range(size[0]):
            px[x, y] = color
    return base


def frame(screen_path, kind, height=1500):
    screen = Image.open(screen_path).convert("RGBA")
    ios = kind == "ios"
    bezel = int(height * (0.020 if ios else 0.022))
    edge = int(height * 0.007)  # metal rim
    screen_h = height * SS - 2 * (bezel + edge) * SS
    screen_w = int(screen.width * screen_h / screen.height)
    screen = screen.resize((screen_w, screen_h), Image.LANCZOS)
    body_w = screen_w + 2 * (bezel + edge) * SS
    body_h = height * SS
    pad = int(height * 0.03) * SS  # room for the side buttons and shadow
    canvas = Image.new("RGBA", (body_w + 2 * pad, body_h + 2 * pad), (0, 0, 0, 0))

    body_r = int(body_w * (0.145 if ios else 0.085))
    screen_r = body_r - (bezel + edge) * SS + int(body_w * 0.004)
    rim = (gradient((body_w, body_h), (178, 182, 188), (92, 96, 102)) if ios
           else gradient((body_w, body_h), (70, 74, 80), (38, 40, 44)))
    canvas.paste(rim, (pad, pad), rounded_mask((body_w, body_h), body_r))

    # side buttons
    d = ImageDraw.Draw(canvas)
    bw = int(height * 0.004) * SS
    btn = (110, 114, 120, 255) if ios else (58, 61, 66, 255)
    right_x = pad + body_w - 1
    left_x = pad - bw + 1
    if ios:
        for y0, h in ((0.17, 0.05), (0.25, 0.085), (0.36, 0.085)):
            d.rounded_rectangle((left_x, pad + int(body_h * y0), left_x + bw, pad + int(body_h * (y0 + h))), bw // 2, fill=btn)
        d.rounded_rectangle((right_x, pad + int(body_h * 0.29), right_x + bw, pad + int(body_h * 0.40)), bw // 2, fill=btn)
    else:
        d.rounded_rectangle((right_x, pad + int(body_h * 0.22), right_x + bw, pad + int(body_h * 0.28)), bw // 2, fill=btn)
        d.rounded_rectangle((right_x, pad + int(body_h * 0.31), right_x + bw, pad + int(body_h * 0.40)), bw // 2, fill=btn)

    # black bezel, then the screen
    inner_w, inner_h = body_w - 2 * edge * SS, body_h - 2 * edge * SS
    black = Image.new("RGBA", (inner_w, inner_h), (4, 4, 6, 255))
    canvas.paste(black, (pad + edge * SS, pad + edge * SS), rounded_mask((inner_w, inner_h), max(2, body_r - edge * SS)))
    sx, sy = pad + (bezel + edge) * SS, pad + (bezel + edge) * SS
    canvas.paste(screen, (sx, sy), rounded_mask(screen.size, screen_r))

    # camera cut-out
    d = ImageDraw.Draw(canvas)
    cx = pad + body_w // 2
    if ios:
        w, h = int(screen_w * 0.29), int(screen_w * 0.085)
        top = sy + int(screen_w * 0.028)
        d.rounded_rectangle((cx - w // 2, top, cx + w // 2, top + h), h // 2, fill=(0, 0, 0, 255))
    else:
        r = int(screen_w * 0.022)
        cy = sy + int(screen_w * 0.052)
        d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=(0, 0, 0, 255))
        d.ellipse((cx - r // 2, cy - r // 2, cx + r // 2, cy + r // 2), fill=(16, 24, 38, 255))

    return canvas.resize((canvas.width // SS, canvas.height // SS), Image.LANCZOS)


def hero(left, right, width=2400, height=1700):
    bg = gradient((width, height), (18, 28, 30), (9, 12, 14))
    glow = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse((width * 0.2, height * 0.1, width * 0.8, height * 0.9), fill=(110, 240, 190, 46))
    bg.alpha_composite(glow.filter(ImageFilter.GaussianBlur(160)))
    scale = (height * 0.88) / left.height
    phones = [p.resize((int(p.width * scale), int(p.height * scale)), Image.LANCZOS) for p in (left, right)]
    gap = int(width * 0.035)
    total = phones[0].width + phones[1].width + gap
    x = (width - total) // 2
    for i, phone in enumerate(phones):
        y = (height - phone.height) // 2 + (int(height * 0.025) if i else -int(height * 0.025))
        shadow = Image.new("RGBA", (width, height), (0, 0, 0, 0))
        ImageDraw.Draw(shadow).rounded_rectangle((x + 30, y + 50, x + phone.width - 30, y + phone.height), 90, fill=(0, 0, 0, 150))
        bg.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(40)))
        bg.alpha_composite(phone, (x, y))
        x += phone.width + gap
    return bg


def main(src, dst):
    src, dst = Path(src), Path(dst)
    dst.mkdir(parents=True, exist_ok=True)
    for lang in ("en", "es"):
        ios = frame(src / f"ios_{lang}.png", "ios")
        android = frame(src / f"and_{lang}.png", "android")
        ios.save(dst / f"ios-framed-{lang}.png", optimize=True)
        android.save(dst / f"android-framed-{lang}.png", optimize=True)
        hero(ios, android).convert("RGB").save(dst / f"devices-{lang}.png", optimize=True)
        print("wrote", lang)


if __name__ == "__main__":
    main(*sys.argv[1:3])
