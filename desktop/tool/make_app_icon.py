#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
# SPDX-License-Identifier: Apache-2.0
"""Builds the macOS app icon set from the phone's 1024 px icon: Apple's
macOS shape (an 824 px rounded square on a 1024 canvas) with a soft shadow.

    python3 desktop/tool/make_app_icon.py \
      app/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png \
      desktop/macos/Runner/Assets.xcassets/AppIcon.appiconset

Needs Pillow."""
import sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

src, out = Path(sys.argv[1]), Path(sys.argv[2])
art = Image.open(src).convert("RGBA").resize((824, 824), Image.LANCZOS)
SS = 4  # supersampled mask for smooth corners
mask = Image.new("L", (824 * SS, 824 * SS), 0)
ImageDraw.Draw(mask).rounded_rectangle((0, 0, 824 * SS - 1, 824 * SS - 1), radius=185 * SS, fill=255)
mask = mask.resize((824, 824), Image.LANCZOS)
canvas = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
shadow = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
shadow.paste((0, 0, 0, 90), (100, 112), mask)
canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(14)))
tile = Image.new("RGBA", (824, 824), (0, 0, 0, 0))
tile.paste(art, (0, 0), mask)
canvas.alpha_composite(tile, (100, 100))
for size in (16, 32, 64, 128, 256, 512, 1024):
    canvas.resize((size, size), Image.LANCZOS).save(out / f"app_icon_{size}.png", optimize=True)
print("ok")
