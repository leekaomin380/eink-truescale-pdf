#!/usr/bin/env python3
"""Render the 1200x630 social / search preview card.

Text-only composition: no device mockup, no screenshot bitmap, no dark frame
or elastic band. Uses only Pillow and the fonts that ship with macOS; no
network access.

    python3 site/make-og-card.py
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ASSETS = Path(__file__).resolve().parent / "assets"
OUT = ASSETS / "og-card.png"
W, H = 1200, 630

GROUND = "#f7f8fa"
INK = "#26292e"
MUTED = "#6b717a"
RULE = "#e0e3e8"
ACCENT = "#416e9c"

SUPPLEMENTAL = Path("/System/Library/Fonts/Supplemental")
BOLD = SUPPLEMENTAL / "Arial Bold.ttf"
REGULAR = SUPPLEMENTAL / "Arial.ttf"


def font(path: Path, size: int) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(str(path), size)


def main() -> None:
    img = Image.new("RGB", (W, H), GROUND)
    draw = ImageDraw.Draw(img)

    # Divider between the copy and the measurement, using the site's rule colour.
    draw.line([(760, 70), (760, 560)], fill=RULE, width=2)

    icon = Image.open(ASSETS / "icon.png").convert("RGBA").resize((96, 96), Image.LANCZOS)
    img.paste(icon, (72, 70), icon)

    draw.text((72, 196), "TRUE-SIZE TYPESETTING FOR E-INK", font=font(BOLD, 19), fill=ACCENT)
    draw.text((68, 240), "TrueScale", font=font(BOLD, 68), fill=INK)
    draw.text((68, 318), "for QUADERNO", font=font(BOLD, 68), fill=INK)
    draw.text((72, 420), "Copy text, press one key, and it opens", font=font(REGULAR, 26), fill=MUTED)
    draw.text((72, 456), "on your QUADERNO at true physical size.", font=font(REGULAR, 26), fill=MUTED)

    draw.rounded_rectangle([(72, 522), (392, 570)], radius=24, fill=ACCENT)
    draw.text((94, 533), "FREE  ·  MIT  ·  macOS 14+", font=font(BOLD, 19), fill="#ffffff")

    # Right column: a typographic measurement instead of a device illustration.
    draw.text((800, 96), "MEASURED, NOT ASSUMED", font=font(BOLD, 19), fill=ACCENT)
    draw.text((792, 148), "1 : 1", font=font(BOLD, 116), fill=INK)
    draw.line([(800, 306), (1140, 306)], fill=RULE, width=2)

    draw.text((800, 342), "100 mm", font=font(BOLD, 28), fill=INK)
    y = 398
    draw.line([(800, y), (1000, y)], fill=MUTED, width=2)
    draw.line([(800, y - 9), (800, y + 9)], fill=MUTED, width=2)
    draw.line([(1000, y - 9), (1000, y + 9)], fill=MUTED, width=2)
    draw.text((800, y + 20), "ON SCREEN = UNDER THE RULER", font=font(REGULAR, 19), fill=MUTED)
    draw.text((800, 474), "156.97 × 209.30 mm", font=font(REGULAR, 24), fill=INK)
    draw.text((800, 512), "227 ppi  ·  NO RESCALING", font=font(REGULAR, 19), fill=MUTED)

    OUT.parent.mkdir(parents=True, exist_ok=True)
    img.save(OUT, optimize=True)
    print(f"wrote {OUT} ({OUT.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
