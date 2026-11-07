"""Generate brand assets from the OnlyLinkCard master icon.

Source of truth: the finished icon artwork (1254x1254, rounded corners,
"OnlyLinkCard / Global Travel eSIM" wordmark baked into the bottom 27%).

Outputs
  assets/brand/app_icon.png         full square icon (rounded corners -> white)
  assets/brand/logo_wordmark.png    icon + wordmark, rounded clip (login page)
  android mipmap-*/ic_launcher.png  legacy launcher icon per density
  android mipmap-*/ic_launcher_foreground.png  adaptive-icon foreground
      (mark only, no wordmark, scaled into the 66/108 safe circle)
  assets_icon_512.png / icon_512.png  store listing icon

Run:  python tools/build_brand_assets.py [source.png]
"""
import sys
import shutil
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_SRC = Path(
    r"C:\Users\Administrator\.openclaw\media\inbound"
    r"\环球飞行_eSIM_旅行图标---817dcf9f-ca5d-4780-ae15-bc53a6ac58e5.png"
)

# fraction of icon height that is wordmark (letters start around here)
TEXT_TOP = 0.735
# adaptive icons: only the middle 66/108 of the canvas is guaranteed visible
SAFE = 66 / 108

MIPMAPS = {
    "mdpi": 48,
    "hdpi": 72,
    "xhdpi": 96,
    "xxhdpi": 144,
    "xxxhdpi": 192,
}


def rounded_mask(size, radius, ss=4):
    """Antialiased rounded-square mask."""
    big = Image.new("L", (size * ss, size * ss), 0)
    ImageDraw.Draw(big).rounded_rectangle(
        [0, 0, size * ss - 1, size * ss - 1], radius=radius * ss, fill=255
    )
    return big.resize((size, size), Image.LANCZOS)


def flatten_square(im, radius_ratio=0.16):
    """Icon with rounded corners composited onto white; corners become white."""
    out = im.convert("RGB")
    m = rounded_mask(out.width, int(out.width * radius_ratio))
    plate = Image.new("RGB", out.size, (255, 255, 255))
    plate.paste(out, (0, 0), m)
    return plate


def rounded_clip(im, radius_ratio=0.16):
    """Icon clipped to rounded corners with transparent outside."""
    out = im.convert("RGBA")
    out.putalpha(rounded_mask(out.width, int(out.width * radius_ratio)))
    return out


def content_bbox(im, thr=245):
    """Bounding box of non-near-white pixels."""
    a = np.asarray(im.convert("RGB")).astype(np.int16)
    mask = (a.min(axis=2) < thr)
    ys, xs = np.where(mask)
    if not len(xs):
        return (0, 0, im.width, im.height)
    return (xs.min(), ys.min(), xs.max() + 1, ys.max() + 1)


def find_square_mark(im):
    """Largest roughly-square block that does not touch the wordmark.

    The master icon is a square; the wordmark spans most of the width, so a
    horizontal projection of ink per row finds the gap above the letters.
    """
    a = np.asarray(im.convert("RGB")).astype(np.int16)
    ink = (a.min(axis=2) < 235).sum(axis=1)
    h = im.height
    # last row-block with ink covering > 45% of width => wordmark band
    wide = np.where(ink > h * 0.0 + im.width * 0.45)[0]
    limit = h * 0.60  # never crop below the middle: the globe lives above it
    wide = wide[wide > limit]
    cut = int(wide.min()) if len(wide) else int(h * TEXT_TOP)
    while cut > 0 and ink[cut - 1] > im.width * 0.45:
        cut -= 1
    # keep a small breathing gap above the letters
    return cut - int(h * 0.012)


def make_mark(im, size):
    """Square mark crop, centered, with transparent padding for adaptive icons."""
    cut = find_square_mark(im)
    top = im.crop((0, 0, im.width, cut))
    bbox = content_bbox(top, thr=240)
    x0, y0, x1, y1 = bbox
    side = max(x1 - x0, y1 - y0)
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    box = (cx - side / 2, cy - side / 2, cx + side / 2, cy + side / 2)
    mark = top.crop(tuple(int(v) for v in box)).resize((size, size), Image.LANCZOS)
    return mark


def adaptive_canvas(mark, size, radius=0):
    """Place mark at 62% of canvas -> fits the 66/108 safe circle."""
    inner = int(round(size * SAFE * 0.94))
    canvas = Image.new("RGBA", (size, size), (255, 255, 255, 255))
    m = mark.resize((inner, inner), Image.LANCZOS)
    off = (size - inner) // 2
    canvas.paste(m, (off, off))
    if radius:
        canvas.putalpha(rounded_mask(size, radius))
    return canvas


def main():
    src = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_SRC
    im = Image.open(src).convert("RGB")
    print("source", src, im.size)

    brand = ROOT / "assets" / "brand"
    brand.mkdir(parents=True, exist_ok=True)

    icon = flatten_square(im)
    # Bundled copies are downsized + optimized: the app only paints them
    # <=160 logical px, so 512/640 keeps every density crisp at ~1/5 the bytes
    # (matters for the iOS build where the asset folder gets zipped as-is).
    icon.resize((512, 512), Image.LANCZOS).save(brand / "app_icon.png", optimize=True)
    rounded_clip(im).resize((640, 640), Image.LANCZOS).save(
        brand / "logo_wordmark.png", optimize=True
    )
    icon.resize((512, 512), Image.LANCZOS).save(ROOT / "assets_icon_512.png")
    icon.resize((512, 512), Image.LANCZOS).save(ROOT / "icon_512.png")

    # ios assets: regenerate EVERY slot in the AppIcon set from the 1024 master.
    # Resizing only the 1024 file leaves the small sizes showing the old icon.
    ios = ROOT / "ios" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
    if ios.is_dir():
        import json

        master = icon.resize((1024, 1024), Image.LANCZOS)
        master.save(ios / "Icon-App-1024x1024@1x.png")
        contents = json.loads((ios / "Contents.json").read_text(encoding="utf-8"))
        for entry in contents.get("images", []):
            fn = entry.get("filename")
            if not fn:
                continue
            px = int(round(float(entry["size"].split("x")[0])
                           * int(entry["scale"][0])))
            master.resize((px, px), Image.LANCZOS).save(
                ios / fn, optimize=True
            )

    mark = make_mark(im, 512)
    mark.save(brand / "mark.png")

    res = ROOT / "android" / "app" / "src" / "main" / "res"
    for name, px in MIPMAPS.items():
        d = res / f"mipmap-{name}"
        d.mkdir(parents=True, exist_ok=True)
        icon.resize((px, px), Image.LANCZOS).save(d / "ic_launcher.png", "PNG")
        adaptive_canvas(mark, px).save(d / "ic_launcher_foreground.png", "PNG")

    # adaptive icon background: sky blue taken from the artwork's top band
    top_band = np.asarray(im.crop((0, 0, im.width, int(im.height * 0.05))))
    bg = tuple(int(v) for v in top_band.reshape(-1, 3).mean(axis=0))
    print("adaptive bg", "#%02X%02X%02X" % bg)
    # The colour lives in values/ic_launcher_background.xml (the file Flutter's
    # icon tooling ships). Writing it into colors.xml too duplicates the
    # resource and breaks aapt2 packaging.
    (res / "values" / "ic_launcher_background.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n'
        f'    <color name="ic_launcher_background">#FF{bg[0]:02X}{bg[1]:02X}{bg[2]:02X}</color>\n'
        "</resources>\n",
        encoding="utf-8",
    )

    # sanity: mark must not contain any wordmark ink in its bottom 8%
    print("mark bottom ink ratio",
          float((np.asarray(mark.convert("L"))[-28:] < 200).mean()))
    print("done")


if __name__ == "__main__":
    main()
