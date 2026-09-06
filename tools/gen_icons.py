#!/usr/bin/env python3
"""Regenerate every FocusFlow icon asset from one mark. Needs Pillow.

    python3 tools/gen_icons.py

Writes the legacy launcher PNGs, the adaptive-icon foreground layers, the Play
Store 512×512 icon and the 1024×500 feature graphic. The mark is a single
tapered stroke spiralling inward — thick where it starts, converging to a point —
chosen because it reads as a spiral (not a letter) at 48 px, and because every
other productivity icon is a checkmark or a ring. Colours are the web app's
`primary` palette (Tailwind sky-500 → sky-700), so the phone and the site match.
"""
import glob, math, os, sys
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = os.path.join(ROOT, "android/app/src/main/res")
STORE = os.path.join(ROOT, "docs/store-assets")
SKY500, SKY700, WHITE = (14, 165, 233), (3, 105, 161), (255, 255, 255)
SS = 4  # supersample, then LANCZOS down: PIL's line joins are ugly at 1×

def gradient(w, h, c0, c1, angle_deg=35):
    d = int(math.hypot(w, h)) + 2
    ramp = Image.linear_gradient("L").resize((d, d)).rotate(angle_deg, resample=Image.BICUBIC)
    ramp = ramp.crop(((d - w) // 2, (d - h) // 2, (d - w) // 2 + w, (d - h) // 2 + h))
    return Image.composite(Image.new("RGB", (w, h), c1), Image.new("RGB", (w, h), c0), ramp)

def rounded_mask(n, frac):
    m = Image.new("L", (n, n), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, n - 1, n - 1], radius=int(n * frac), fill=255)
    return m

def mark(size, bg=None, turns=1.85, start=math.pi, w_max=0.13, w_min=0.045, r_max=0.39, scale=1.0):
    """The spiral, drawn as ~1200 short segments of decreasing width with round joints."""
    n = size * SS
    img = Image.new("RGBA", (n, n), (0, 0, 0, 0)) if bg is None else bg.copy()
    d = ImageDraw.Draw(img)
    cx = cy = n / 2
    steps = 1200
    pts = []
    for i in range(steps + 1):
        t = i / steps
        r = n * r_max * scale * (1 - t) ** 0.92
        ang = start + turns * 2 * math.pi * t
        pts.append((cx + r * math.cos(ang), cy + r * math.sin(ang), n * scale * (w_max + (w_min - w_max) * t)))
    for (x0, y0, w0), (x1, y1, w1) in zip(pts, pts[1:]):
        w = (w0 + w1) / 2
        d.line([(x0, y0), (x1, y1)], fill=WHITE, width=max(1, int(w)))
        d.ellipse([x1 - w / 2, y1 - w / 2, x1 + w / 2, y1 + w / 2], fill=WHITE)
    x0, y0, w0 = pts[0]
    d.ellipse([x0 - w0 / 2, y0 - w0 / 2, x0 + w0 / 2, y0 + w0 / 2], fill=WHITE)  # round outer terminal
    return img

def font(size, bold=True):
    names = ["Inter-Bold", "Roboto-Bold", "NotoSans-Bold", "DejaVuSans-Bold"] if bold else \
            ["Inter-Regular", "Roboto-Regular", "NotoSans-Regular", "DejaVuSans"]
    for name in names:
        hits = glob.glob(f"/usr/share/fonts/**/{name}.ttf", recursive=True)
        if hits:
            return ImageFont.truetype(hits[0], size)
    return ImageFont.load_default()

DENSITIES = (("mdpi", 1), ("hdpi", 1.5), ("xhdpi", 2), ("xxhdpi", 3), ("xxxhdpi", 4))

def main():
    os.makedirs(STORE, exist_ok=True)
    # Legacy launcher: 48dp rounded square with transparent corners (pre-Android-8 launchers).
    for dpi, k in DENSITIES:
        px = int(48 * k); n = px * SS
        bg = gradient(n, n, SKY500, SKY700).convert("RGBA"); bg.putalpha(rounded_mask(n, 0.2))
        out = os.path.join(RES, f"mipmap-{dpi}"); os.makedirs(out, exist_ok=True)
        mark(px, bg=bg).resize((px, px), Image.LANCZOS).save(os.path.join(out, "ic_launcher.png"))
    # Adaptive foreground: 108dp canvas, the mark kept inside the 66dp safe zone so no
    # launcher shape (circle, squircle, teardrop) clips it. Background is a colour resource.
    for dpi, k in DENSITIES:
        px = int(108 * k); s = 66 / 108
        out = os.path.join(RES, f"mipmap-{dpi}")
        mark(px, scale=s).resize((px, px), Image.LANCZOS).save(os.path.join(out, "ic_launcher_foreground.png"))
    # Play Store hi-res icon: full-bleed square, NO transparency — Play applies its own mask.
    n = 512 * SS
    mark(512, bg=gradient(n, n, SKY500, SKY700).convert("RGBA")).convert("RGB") \
        .resize((512, 512), Image.LANCZOS).save(os.path.join(STORE, "playstore-icon-512.png"))
    # Feature graphic 1024×500: mark left, wordmark right, one plain sentence.
    W, H = 1024, 500
    fg = gradient(W * SS, H * SS, SKY500, SKY700, angle_deg=20).convert("RGBA")
    m = mark(360).resize((360 * SS, 360 * SS), Image.LANCZOS); fg.paste(m, (80 * SS, 70 * SS), m)
    d = ImageDraw.Draw(fg)
    d.text((480 * SS, 168 * SS), "FocusFlow", font=font(92 * SS), fill=WHITE)
    d.text((484 * SS, 292 * SS), "Tasks, habits, goals and focus,", font=font(31 * SS, False), fill=(255, 255, 255, 235))
    d.text((484 * SS, 334 * SS), "synced to a server you run.", font=font(31 * SS, False), fill=(255, 255, 255, 235))
    fg.convert("RGB").resize((W, H), Image.LANCZOS).save(os.path.join(STORE, "feature-graphic-1024x500.png"))
    print("wrote launcher ×5, adaptive foreground ×5, playstore-icon-512.png, feature-graphic-1024x500.png")

if __name__ == "__main__":
    main()
