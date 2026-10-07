#!/usr/bin/env python3
"""Generate the FreeAudio app icon: FreeDisplay's blue-to-purple tile with a white three-band
equalizer (faders at different heights), matching the `slider.vertical.3` menu bar symbol.
Writes every size into FreeAudio/Assets.xcassets/AppIcon.appiconset.

    python3 scripts/generate-icon.py             (needs Pillow: pip3 install pillow)
    python3 scripts/generate-icon.py preview.png (writes only a 1024 px preview)
"""

import os
import sys
from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
CORNER_RADIUS = int(SIZE * 0.18)
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICONSET = os.path.join(ROOT, "FreeAudio", "Assets.xcassets", "AppIcon.appiconset")
SIZES = [16, 32, 64, 128, 256, 512, 1024]


def rounded_mask(size, radius):
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    return mask


def gradient(size, top, bottom):
    """Vertical gradient, the same colours as FreeDisplay (#4A90D9 → #7B68EE)."""
    img = Image.new("RGBA", (size, size))
    draw = ImageDraw.Draw(img)
    for y in range(size):
        t = y / (size - 1)
        color = tuple(int(a + (b - a) * t) for a, b in zip(top, bottom)) + (255,)
        draw.line([(0, y), (size, y)], fill=color)
    return img


def equalizer_layer(offset=(0, 0)):
    """Three white faders (track + knob) at different heights on a transparent layer."""
    layer = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    ox, oy = offset

    def p(x, y):
        return (int(SIZE * x + ox), int(SIZE * y + oy))

    top, bottom = 0.235, 0.765
    track_w, knob_w, knob_h = 0.046, 0.165, 0.095
    for x, knob_y in [(0.30, 0.60), (0.50, 0.37), (0.70, 0.53)]:
        # Track: dimmer above the knob, brighter below it (the "filled" part of the fader).
        draw.rounded_rectangle([p(x - track_w / 2, top), p(x + track_w / 2, bottom)],
                               radius=int(SIZE * track_w / 2), fill=(255, 255, 255, 110))
        draw.rounded_rectangle([p(x - track_w / 2, knob_y), p(x + track_w / 2, bottom)],
                               radius=int(SIZE * track_w / 2), fill=(255, 255, 255, 215))
        draw.rounded_rectangle([p(x - knob_w / 2, knob_y - knob_h / 2), p(x + knob_w / 2, knob_y + knob_h / 2)],
                               radius=int(SIZE * knob_h / 2), fill=(255, 255, 255, 255))
    return layer


def main():
    tile = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    tile.paste(gradient(SIZE, (74, 144, 217), (123, 104, 238)), (0, 0), rounded_mask(SIZE, CORNER_RADIUS))

    # Soft shadow under the faders, like the monitor in FreeDisplay's icon.
    shadow = equalizer_layer(offset=(0, int(SIZE * 0.018)))
    alpha = shadow.split()[3].point(lambda a: int(a * 0.28))
    shadow = Image.merge("RGBA", (Image.new("L", shadow.size, 0),) * 3 + (alpha,)).filter(ImageFilter.GaussianBlur(SIZE * 0.012))
    tile = Image.alpha_composite(tile, shadow)
    tile = Image.alpha_composite(tile, equalizer_layer())

    if len(sys.argv) > 1:
        tile.save(sys.argv[1], "PNG")
        print(f"Saved preview: {sys.argv[1]}")
        return
    for size in SIZES:
        path = os.path.join(ICONSET, f"icon_{size}.png")
        tile.resize((size, size), Image.LANCZOS).save(path, "PNG")
        print(f"Saved: {path}")


if __name__ == "__main__":
    main()
