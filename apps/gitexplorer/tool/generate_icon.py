"""Builds GitExplorer launcher icons from the generated source mark.

The source artwork lives at assets/icon/gitexplorer_mark.png. This script
places it on the app's dark plate and produces every platform-specific icon,
the web favicon, and a multi-resolution Windows icon.

Run from apps/gitexplorer:  python tool/generate_icon.py
"""

import json
from pathlib import Path

from PIL import Image, ImageDraw

GRID = 1024
SS = 4
S = GRID * SS

BG_TOP = (40, 50, 66)
BG_BOTTOM = (15, 19, 26)


def vertical_gradient(top, bottom):
    """Returns a supersampled background gradient."""
    grad = Image.new("RGB", (1, S))
    pixels = grad.load()
    for y in range(S):
        t = y / (S - 1)
        pixels[0, y] = tuple(
            round(start + (end - start) * t) for start, end in zip(top, bottom)
        )
    return grad.resize((S, S))


def background(radius):
    """Builds an opaque square or transparent rounded app plate."""
    plate = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    mask = Image.new("L", (S, S), 255)
    if radius:
        mask = Image.new("L", (S, S), 0)
        ImageDraw.Draw(mask).rounded_rectangle(
            [0, 0, S - 1, S - 1], radius=round(radius * SS), fill=255
        )
    plate.paste(vertical_gradient(BG_TOP, BG_BOTTOM), (0, 0), mask)
    return plate.resize((GRID, GRID), Image.Resampling.LANCZOS)


def source_mark(out):
    """Loads the transparent, high-resolution generated mark."""
    source = out / "gitexplorer_mark.png"
    mark = Image.open(source).convert("RGBA")
    if not mark.getbbox():
        raise ValueError(f"source mark is empty: {source}")
    return mark


def fit(mark, coverage):
    """Centres a cropped mark on a transparent 1024 canvas."""
    cropped = mark.crop(mark.getbbox())
    target = round(GRID * coverage)
    scale = target / max(cropped.size)
    size = (
        max(1, round(cropped.width * scale)),
        max(1, round(cropped.height * scale)),
    )
    canvas = Image.new("RGBA", (GRID, GRID), (0, 0, 0, 0))
    canvas.paste(
        cropped.resize(size, Image.Resampling.LANCZOS),
        ((GRID - size[0]) // 2, (GRID - size[1]) // 2),
    )
    return canvas


def asset_catalog_sizes(catalog):
    """Yields each unique filename and its pixel size from an Apple catalog."""
    contents = json.loads((catalog / "Contents.json").read_text())
    emitted = set()
    for image in contents["images"]:
        filename = image.get("filename")
        if not filename or filename in emitted:
            continue
        points = float(image["size"].split("x", 1)[0])
        scale = int(image["scale"].removesuffix("x"))
        emitted.add(filename)
        yield filename, round(points * scale)


def write_platform_icons(app, square, rounded, macos, foreground):
    """Writes the Android and Apple launcher icon sets."""
    android = app / "android" / "app" / "src" / "main" / "res"
    densities = {
        "mdpi": (48, 108),
        "hdpi": (72, 162),
        "xhdpi": (96, 216),
        "xxhdpi": (144, 324),
        "xxxhdpi": (192, 432),
    }
    for density, (legacy_size, foreground_size) in densities.items():
        legacy_dir = android / f"mipmap-{density}"
        foreground_dir = android / f"drawable-{density}"
        legacy_dir.mkdir(parents=True, exist_ok=True)
        foreground_dir.mkdir(parents=True, exist_ok=True)
        rounded.resize(
            (legacy_size, legacy_size), Image.Resampling.LANCZOS
        ).save(legacy_dir / "ic_launcher.png")
        foreground.resize(
            (foreground_size, foreground_size), Image.Resampling.LANCZOS
        ).save(foreground_dir / "ic_launcher_foreground.png")

    ios = app / "ios" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
    for filename, size in asset_catalog_sizes(ios):
        square.resize((size, size), Image.Resampling.LANCZOS).save(ios / filename)

    mac = app / "macos" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
    for filename, size in asset_catalog_sizes(mac):
        macos.resize((size, size), Image.Resampling.LANCZOS).save(mac / filename)


def main():
    out = Path(__file__).resolve().parent.parent / "assets" / "icon"
    app = out.parent.parent
    out.mkdir(parents=True, exist_ok=True)

    source = source_mark(out)
    mark = fit(source, 0.82)

    # Full-bleed square: iOS and Windows mask or frame it themselves.
    square = background(0)
    square.alpha_composite(mark)
    square.convert("RGB").save(out / "app_icon.png")

    # Rounded, for surfaces that show the icon unmasked (Linux, Android legacy).
    rounded = background(200)
    rounded.alpha_composite(mark)
    rounded.save(out / "app_icon_rounded.png")

    # macOS expects breathing room and applies no mask of its own.
    macos = Image.new("RGBA", (GRID, GRID), (0, 0, 0, 0))
    inset = round(GRID * 0.08)
    plate = background(200).resize(
        (GRID - 2 * inset, GRID - 2 * inset), Image.Resampling.LANCZOS
    )
    plate.alpha_composite(mark.resize(plate.size, Image.Resampling.LANCZOS))
    macos.paste(plate, (inset, inset))
    macos.save(out / "app_icon_macos.png")

    # Android adaptive icons receive their own platform background.
    foreground = fit(source, 0.72)
    foreground.save(out / "app_icon_foreground.png")

    # Keep small Windows taskbar sizes inside the .ico instead of relying on
    # downscaling from a lone 256 px image.
    ico = app / "windows" / "runner" / "resources" / "app_icon.ico"
    sizes = [16, 24, 32, 48, 64, 128, 256]
    rounded.save(ico, sizes=[(size, size) for size in sizes])

    # Maskable web icons need extra safe-area padding for arbitrary crops.
    web = app / "web"
    maskable = background(0)
    maskable.alpha_composite(fit(source, 0.62))
    for size in (192, 512):
        rounded.resize((size, size), Image.Resampling.LANCZOS).save(
            web / "icons" / f"Icon-{size}.png"
        )
        maskable.resize((size, size), Image.Resampling.LANCZOS).save(
            web / "icons" / f"Icon-maskable-{size}.png"
        )
    rounded.resize((32, 32), Image.Resampling.LANCZOS).save(web / "favicon.png")

    write_platform_icons(app, square, rounded, macos, foreground)

    print(f"built launcher artwork from {out / 'gitexplorer_mark.png'}")


if __name__ == "__main__":
    main()
