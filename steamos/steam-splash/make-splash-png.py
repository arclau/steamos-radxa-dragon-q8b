#!/usr/bin/env python3
"""Regenerate steamos/steam-splash/splash.png (the first-boot Steam-update splash).

Why this script exists
----------------------
The splash is shown fullscreen while the Steam client bootstrap downloads its
~650 MB payload (first boot / stale image), so the user does not see a pure black
screen and think the board is bricked.

The PNG is COMMITTED to git (deterministic bytes). This generator is only for
regeneration, so the build never depends on the host's ImageMagick/PIL/FreeType
versions (which would make the image bytes non-reproducible).

Font: the CJK font ships INSIDE the SteamOS rootfs, so we render with exactly the
font the target would have used. Point FONT at a SteamOS rootfs extracted tree
(`make steamos-rootfs` produces build/steamos-rootfs). The host usually has no CJK
font installed, hence reading the .ttc straight out of the rootfs.

Usage:
    python3 steamos/steam-splash/make-splash-png.py
    FONT=/path/to/NotoSansCJK-Bold.ttc python3 steamos/steam-splash/make-splash-png.py
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "splash.png")

FONT = os.environ.get(
    "FONT",
    "/data/rock8bq/build/steamos-rootfs/usr/share/fonts/noto-cjk/NotoSansCJK-Bold.ttc",
)
# Optional Steam logo to draw above the text (from the same rootfs). Skipped if absent.
ICON = os.environ.get(
    "ICON",
    "/data/rock8bq/build/steamos-rootfs/usr/share/steamos/steam_icon.png",
)

W, H = 1920, 1080
BG = "#171a21"        # Steam dark
FG = "#ffffff"
SUB = "#c7d5e0"       # Steam muted blue-grey

TITLE = "正在更新 Steam…"
SUBTITLE = "首次启动需下载组件，请勿断电"


def main() -> int:
    if not os.path.isfile(FONT):
        print(f"ERROR: font not found: {FONT}", file=sys.stderr)
        print("Hint: run `make steamos-rootfs` first, or set FONT=<NotoSansCJK-Bold.ttc>",
              file=sys.stderr)
        return 1

    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)

    title_font = ImageFont.truetype(FONT, 72, index=0)
    sub_font = ImageFont.truetype(FONT, 40, index=0)

    # Optional logo, centered above the title.
    if os.path.isfile(ICON):
        try:
            logo = Image.open(ICON).convert("RGBA")
            logo.thumbnail((220, 220), Image.LANCZOS)
            img.paste(logo, ((W - logo.width) // 2, 300), logo)
        except Exception as e:  # best-effort, cosmetic only
            print(f"WARN: could not draw icon {ICON}: {e}", file=sys.stderr)

    d.text((W // 2, 600), TITLE, font=title_font, fill=FG, anchor="mm")
    d.text((W // 2, 700), SUBTITLE, font=sub_font, fill=SUB, anchor="mm")

    img.save(OUT, "PNG", optimize=True)
    print(f"wrote {OUT} ({os.path.getsize(OUT)} bytes, {W}x{H})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
