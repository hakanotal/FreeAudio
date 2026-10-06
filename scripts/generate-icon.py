#!/usr/bin/env python3
"""Generate the FreeAudio app icon: FreeDisplay's blue-to-purple tile with a white speaker and
sound waves. Writes every size into FreeAudio/Assets.xcassets/AppIcon.appiconset.

    python3 scripts/generate-icon.py      (needs Pillow: pip3 install pillow)
"""

import os
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


def speaker_layer(scale=1.0, offset=(0, 0)):
    """White speaker and three sound waves on a transparent layer."""
    layer = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    ox, oy = offset

    def p(x, y):
        return (int(SIZE * x * scale + ox), int(SIZE * y * scale + oy))

    white = (255, 255, 255, 235)
    # Speaker body and cone.
    draw.rounded_rectangle([p(0.20, 0.405), p(0.33, 0.595)], radius=int(SIZE * 0.022), fill=white)
    draw.polygon([p(0.31, 0.405), p(0.48, 0.265), p(0.48, 0.735), p(0.31, 0.595)], fill=white)
    draw.rounded_rectangle([p(0.455, 0.265), p(0.50, 0.735)], radius=int(SIZE * 0.022), fill=white)

    # Sound waves: concentric arcs, fading outwards.
    center = p(0.50, 0.50)
    width = int(SIZE * 0.042)
    for radius, alpha in [(0.13, 235), (0.215, 200), (0.30, 165)]:
        r = int(SIZE * radius)
        box = [center[0] - r, center[1] - r, center[0] + r, center[1] + r]
        draw.arc(box, start=-42, end=42, fill=(255, 255, 255, alpha), width=width)
    return layer


def main():
    tile = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    tile.paste(gradient(SIZE, (74, 144, 217), (123, 104, 238)), (0, 0), rounded_mask(SIZE, CORNER_RADIUS))

    # Soft shadow under the speaker, like the monitor in FreeDisplay's icon.
    shadow = speaker_layer(offset=(int(SIZE * 0.012) - int(SIZE * 0.01), int(SIZE * 0.018)))
    alpha = shadow.split()[3].point(lambda a: int(a * 0.25))
    shadow = Image.merge("RGBA", (Image.new("L", shadow.size, 0),) * 3 + (alpha,)).filter(ImageFilter.GaussianBlur(SIZE * 0.012))
    tile = Image.alpha_composite(tile, shadow)
    tile = Image.alpha_composite(tile, speaker_layer(offset=(-int(SIZE * 0.01), 0)))

    for size in SIZES:
        path = os.path.join(ICONSET, f"icon_{size}.png")
        tile.resize((size, size), Image.LANCZOS).save(path, "PNG")
        print(f"Saved: {path}")


if __name__ == "__main__":
    main()
