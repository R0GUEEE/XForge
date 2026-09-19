#!/usr/bin/env python3
"""Generate XForge's app icon and asset catalog.

Motif: a terminal prompt (">_") in an ember gradient on a deep slate panel --
"XForge" = a shell plus a forge. Drawn from a single 1024px master and resized,
then the AppIcon.appiconset Contents.json is written.

Supersampled (drawn at 3x, downscaled) so the strokes stay clean.
"""
import json
import os

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.environ.get("ASSETCATALOG", "Support/Assets.xcassets")
SIZE = 1024
SS = 3  # supersample factor

# Palette
TOP = (24, 28, 50)        # deep indigo
BOTTOM = (8, 10, 18)      # near black
EMBER = (255, 92, 44)     # forge ember
AMBER = (255, 198, 110)   # hot metal


def vertical_gradient(size, top, bottom):
    grad = Image.new("L", (1, size))
    for y in range(size):
        grad.putpixel((0, y), int(255 * y / (size - 1)))
    grad = grad.resize((size, size))
    return Image.composite(
        Image.new("RGB", (size, size), bottom),
        Image.new("RGB", (size, size), top),
        grad,
    )


def radial_mask(size, cx, cy, radius, strength=255):
    """A soft radial blob used to place the ember glow."""
    big = size * 2
    mask = Image.new("L", (big, big), 0)
    ImageDraw.Draw(mask).ellipse(
        [big * cx - radius, big * cy - radius, big * cx + radius, big * cy + radius],
        fill=strength,
    )
    mask = mask.filter(ImageFilter.GaussianBlur(radius * 0.55))
    return mask.resize((size, size), Image.LANCZOS)


def build_master():
    s = SIZE * SS

    # --- background: slate gradient + ember glow from the bottom right -------
    bg = vertical_gradient(SIZE, TOP, BOTTOM)
    glow = radial_mask(SIZE, 0.80, 0.88, SIZE * 0.38, strength=190)
    bg = Image.composite(Image.new("RGB", (SIZE, SIZE), EMBER), bg, glow)
    # and a faint cool light from the top left, for depth
    cool = radial_mask(SIZE, 0.14, 0.08, SIZE * 0.46, strength=70)
    bg = Image.composite(Image.new("RGB", (SIZE, SIZE), (90, 120, 220)), bg, cool)

    # --- foreground: the ">_" prompt, drawn as a mask ------------------------
    mask = Image.new("L", (s, s), 0)
    d = ImageDraw.Draw(mask)
    w = int(0.092 * s)

    chevron = [(0.265 * s, 0.335 * s), (0.470 * s, 0.500 * s), (0.265 * s, 0.665 * s)]
    d.line(chevron, fill=255, width=w, joint="curve")
    for pt in (chevron[0], chevron[-1]):
        d.ellipse([pt[0] - w / 2, pt[1] - w / 2, pt[0] + w / 2, pt[1] + w / 2], fill=255)

    underscore = [(0.535 * s, 0.665 * s), (0.775 * s, 0.665 * s)]
    d.line(underscore, fill=255, width=w)
    for pt in underscore:
        d.ellipse([pt[0] - w / 2, pt[1] - w / 2, pt[0] + w / 2, pt[1] + w / 2], fill=255)

    mask = mask.resize((SIZE, SIZE), Image.LANCZOS)

    # --- fill the prompt with a diagonal amber -> ember gradient -------------
    stroke_grad = vertical_gradient(SIZE, AMBER, EMBER)
    out = Image.composite(stroke_grad, bg, mask)
    return out.convert("RGB")


# (idiom, base-point size, scale, filename) -- the full legacy + modern set.
ENTRIES = [
    ("iphone", "20x20", "2x", "icon-20@2x.png"),
    ("iphone", "20x20", "3x", "icon-20@3x.png"),
    ("iphone", "29x29", "2x", "icon-29@2x.png"),
    ("iphone", "29x29", "3x", "icon-29@3x.png"),
    ("iphone", "40x40", "2x", "icon-40@2x.png"),
    ("iphone", "40x40", "3x", "icon-40@3x.png"),
    ("iphone", "60x60", "2x", "icon-60@2x.png"),
    ("iphone", "60x60", "3x", "icon-60@3x.png"),
    ("ipad", "20x20", "1x", "icon-20.png"),
    ("ipad", "20x20", "2x", "icon-20@2x~ipad.png"),
    ("ipad", "29x29", "1x", "icon-29.png"),
    ("ipad", "29x29", "2x", "icon-29@2x~ipad.png"),
    ("ipad", "40x40", "1x", "icon-40.png"),
    ("ipad", "40x40", "2x", "icon-40@2x~ipad.png"),
    ("ipad", "76x76", "1x", "icon-76.png"),
    ("ipad", "76x76", "2x", "icon-76@2x.png"),
    ("ipad", "83.5x83.5", "2x", "icon-83.5@2x.png"),
    # Modern single-size icon. Xcode needs the platform key and NO scale key.
    ("universal", "1024x1024", "1x", "icon-1024.png"),
]


def main():
    iconset = os.path.join(ROOT, "AppIcon.appiconset")
    accent = os.path.join(ROOT, "AccentColor.colorset")
    os.makedirs(iconset, exist_ok=True)
    os.makedirs(accent, exist_ok=True)

    master = build_master()
    master.save(os.path.join(iconset, "icon-1024.png"))

    images = []
    for idiom, base, scale, name in ENTRIES:
        pts = float(base.split("x")[0])
        mult = float(scale.rstrip("x"))
        px = int(round(pts * mult))
        img = master.resize((px, px), Image.LANCZOS)

        if idiom == "ipad" and name.endswith("~ipad.png"):
            # distinct filename, same pixels as the iphone counterpart
            img.save(os.path.join(iconset, name))
        elif name != "icon-1024.png":
            img.save(os.path.join(iconset, name))

        entry = {"idiom": idiom, "size": base, "filename": name}
        if idiom == "universal":
            entry["platform"] = "ios"          # no "scale" key for this one
        else:
            entry["scale"] = scale
        images.append(entry)

    with open(os.path.join(iconset, "Contents.json"), "w") as f:
        json.dump({"images": images,
                   "info": {"author": "xcode", "version": 1}}, f, indent=2)
        f.write("\n")

    with open(os.path.join(ROOT, "Contents.json"), "w") as f:
        json.dump({"info": {"author": "xcode", "version": 1}}, f, indent=2)
        f.write("\n")

    with open(os.path.join(accent, "Contents.json"), "w") as f:
        json.dump({
            "colors": [{
                "idiom": "universal",
                "color": {
                    "color-space": "srgb",
                    "components": {"red": "1.000", "green": "0.361",
                                   "blue": "0.173", "alpha": "1.000"},
                },
            }],
            "info": {"author": "xcode", "version": 1},
        }, f, indent=2)
        f.write("\n")

    print("master:", master.size)
    print("wrote", len(images), "icon entries to", iconset)


if __name__ == "__main__":
    main()
