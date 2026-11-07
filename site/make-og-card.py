#!/usr/bin/env python3
"""Render the 1200x630 social / search preview card from the existing site assets.

Kept as a script rather than a hand-drawn binary so the card can be regenerated
when the icon or the device screenshot changes. Uses only Pillow and the fonts
that ship with macOS; no network access.

    python3 site/make-og-card.py
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ASSETS = Path(__file__).resolve().parent / "assets"
OUT = ASSETS / "og-card.png"
W, H = 1200, 630

GROUND = "#f6f4ee"
INK = "#1b1b19"
MUTED = "#5d5c57"
RULE = "#dedbd2"
ACCENT = "#1f6b5f"
FRAME = "#2b2b29"
BAND = "#b9472f"

SUPPLEMENTAL = Path("/System/Library/Fonts/Supplemental")
BOLD = SUPPLEMENTAL / "Arial Bold.ttf"
REGULAR = SUPPLEMENTAL / "Arial.ttf"


def font(path: Path, size: int) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(str(path), size)


def main() -> None:
    img = Image.new("RGB", (W, H), GROUND)
    draw = ImageDraw.Draw(img)

    # Divider between the copy and the device, using the site's rule colour.
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

    # Device frame: same dark body and right-hand elastic band as the page.
    frame = (790, 48, 1170, 582)
    draw.rounded_rectangle([(frame[0] + 8, frame[1] + 10), (frame[2] + 8, frame[3] + 10)],
                           radius=26, fill="#e2dfd6")
    draw.rounded_rectangle(frame, radius=26, fill=FRAME)

    page = Image.open(ASSETS / "device-page.png").convert("RGB")
    page_h = 458
    page_w = round(page.width * page_h / page.height)
    page = page.resize((page_w, page_h), Image.LANCZOS)
    page_x = frame[0] + (frame[2] - frame[0] - page_w) // 2
    page_y = frame[1] + 18
    draw.rounded_rectangle([(page_x - 2, page_y - 2), (page_x + page_w + 2, page_y + page_h + 2)],
                           radius=4, fill="#f4f3ef")
    img.paste(page, (page_x, page_y))
    draw.rounded_rectangle([(frame[2] - 14, frame[1] - 8), (frame[2] - 2, frame[3] + 8)],
                           radius=5, fill=BAND)

    OUT.parent.mkdir(parents=True, exist_ok=True)
    img.save(OUT, optimize=True)
    print(f"wrote {OUT} ({OUT.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
