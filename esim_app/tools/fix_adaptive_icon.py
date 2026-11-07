"""Regenerate Android adaptive-icon foreground layers with the correct safe zone.

Android applies a shape mask (circle / squircle / rounded square) to the
adaptive icon and only shows the inner ~72dp of the 108dp canvas. Key content
must sit inside that safe zone or it gets clipped -- which is why the current
foreground looked squat and cropped: the artwork was drawn edge to edge.

Layout used here (per the adaptive-icon spec):
    canvas        108dp  (full bitmap)
    visible area  ~72dp  (66.7% of the canvas, centred)
    safe margin   ~18dp  (16.7%) on each side

So we render the artwork at 62% of the canvas and centre it, leaving >18dp of
transparency around it. 108dp keeps the density scaling right:
    mdpi 1x   -> 108     hdpi 1.5x -> 162
    xhdpi 2x  -> 216     xxhdpi 3x -> 324     xxxhdpi 4x -> 432
"""
import os

from PIL import Image

SRC = os.path.join(os.path.dirname(__file__), "..", "assets", "brand", "app_icon.png")
RES = os.path.join(os.path.dirname(__file__), "..", "android", "app", "src", "main", "res")

# density name -> (dp) scale factor for the 108dp canvas
DENSITIES = {
    "mdpi": 108,
    "hdpi": 162,
    "xhdpi": 216,
    "xxhdpi": 324,
    "xxxhdpi": 432,
}

# Fraction of the canvas the artwork occupies. 0.62 leaves 19% padding per side,
# comfortably inside the 72/108 = 0.667 visible circle.
ART_RATIO = 0.62


def build_foreground(src_path):
    """Cut the artwork out of its plate and centre it on a transparent canvas."""
    im = Image.open(src_path).convert("RGBA")
    w, h = im.size

    # The source is a full-bleed plate with the logo plus wordmark. For the
    # adaptive foreground we only want the mark, and we need no plate at all
    # (the background layer supplies the colour). Find the opaque artwork.
    alpha = im.getchannel("A")
    bbox = alpha.getbbox()
    if bbox:
        im = im.crop(bbox)

    # Square it off so the mark is not squashed when scaled into the canvas.
    w, h = im.size
    side = max(w, h)
    square = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    square.paste(im, ((side - w) // 2, (side - h) // 2))
    return square


def main():
    art = build_foreground(SRC)
    print(f"source artwork cropped to {art.size}")

    for name, canvas in DENSITIES.items():
        target = int(round(canvas * ART_RATIO))
        scaled = art.resize((target, target), Image.LANCZOS)
        out = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
        off = (canvas - target) // 2
        out.paste(scaled, (off, off), scaled)

        path = os.path.join(RES, f"mipmap-{name}", "ic_launcher_foreground.png")
        out.save(path, "PNG", optimize=True)
        pad_pct = off / canvas * 100
        print(f"  {name:8} {canvas}x{canvas}  art={target}px  padding={pad_pct:.1f}%")


if __name__ == "__main__":
    main()
