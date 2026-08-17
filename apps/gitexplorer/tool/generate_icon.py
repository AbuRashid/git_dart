"""Draws the gitexplorer app icon masters into assets/icon/.

The mark merges the two things the app is: a folder (file explorer) whose
contents are a git commit graph. Everything is drawn on a 1024 design grid at
4x supersampling, so the masters are crisp at launcher sizes.

Run from apps/gitexplorer:  python tool/generate_icon.py
Then regenerate the per-platform icons:  dart run flutter_launcher_icons
"""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

GRID = 1024  # design grid
SS = 4  # supersampling factor
S = GRID * SS

GIT_ORANGE = (240, 81, 51)
GIT_ORANGE_DEEP = (203, 60, 35)
BG_TOP = (40, 50, 66)
BG_BOTTOM = (15, 19, 26)
BACK_TOP = (154, 170, 189)
BACK_BOTTOM = (118, 134, 154)
FRONT_TOP = (255, 255, 255)
FRONT_BOTTOM = (219, 228, 238)

# Folder geometry, design units.
TAB = (152, 250, 470, 420)
BACK_BODY = (152, 318, 872, 800)
FRONT_BODY = (152, 392, 872, 800)
CORNER = 48
TAB_CORNER = 40

# Commit graph, design units.
TRUNK_X = 392
TRUNK_TOP = 484
TRUNK_BOTTOM = 726
BRANCH_FROM_Y = 626
BRANCH_NODE = (642, 516)
NODE_R = 46
STROKE = 30


def u(*values):
    """Scales design units to supersampled pixels."""
    return [round(v * SS) for v in values]


def vertical_gradient(top, bottom, y0, y1):
    """A full-canvas image whose colour ramps from top to bottom between y0/y1."""
    grad = Image.new("RGB", (1, S))
    pixels = grad.load()
    span = max(1, round((y1 - y0) * SS))
    start = round(y0 * SS)
    for y in range(S):
        t = min(1.0, max(0.0, (y - start) / span))
        pixels[0, y] = tuple(round(a + (b - a) * t) for a, b in zip(top, bottom))
    return grad.resize((S, S))


def paint(layer, mask, top, bottom, y0, y1):
    """Fills `mask` on `layer` with a vertical gradient."""
    layer.paste(vertical_gradient(top, bottom, y0, y1), (0, 0), mask)


def folder_mask():
    """The whole folder silhouette: tab plus back body."""
    mask = Image.new("L", (S, S), 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle(u(*TAB), radius=TAB_CORNER * SS, fill=255)
    draw.rounded_rectangle(u(*BACK_BODY), radius=CORNER * SS, fill=255)
    return mask


def bezier(p0, p1, p2, p3, steps=96):
    points = []
    for i in range(steps + 1):
        t = i / steps
        m = 1 - t
        x = m**3 * p0[0] + 3 * m**2 * t * p1[0] + 3 * m * t**2 * p2[0] + t**3 * p3[0]
        y = m**3 * p0[1] + 3 * m**2 * t * p1[1] + 3 * m * t**2 * p2[1] + t**3 * p3[1]
        points.append((x * SS, y * SS))
    return points


def stroke(draw, points, width, colour):
    """A round-capped stroke, swept as overlapping discs.

    Pillow's thick `line` seams visibly where segments meet on a curve, so the
    path is resampled and stamped instead.
    """
    r = width * SS / 2
    step = max(1.0, r / 3)
    for (x0, y0), (x1, y1) in zip(points, points[1:]):
        dx, dy = x1 - x0, y1 - y0
        length = (dx * dx + dy * dy) ** 0.5
        for i in range(max(1, int(length / step)) + 1):
            t = min(1.0, i * step / length) if length else 0.0
            x, y = x0 + dx * t, y0 + dy * t
            draw.ellipse([x - r, y - r, x + r, y + r], fill=colour)


def node(draw, centre, colour):
    x, y = centre[0] * SS, centre[1] * SS
    r = NODE_R * SS
    draw.ellipse([x - r, y - r, x + r, y + r], fill=colour)


def render_art():
    """The folder-with-a-commit-graph mark, on transparency, at 1024."""
    art = Image.new("RGBA", (S, S), (0, 0, 0, 0))

    silhouette = folder_mask()

    # A soft drop shadow lifts the folder off the dark background.
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    shadow.paste((6, 9, 14, 130), (0, round(18 * SS)), silhouette)
    art.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(20 * SS)))

    back = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    paint(back, silhouette, BACK_TOP, BACK_BOTTOM, TAB[1], BACK_BODY[3])
    art.alpha_composite(back)

    front_mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(front_mask).rounded_rectangle(
        u(*FRONT_BODY), radius=CORNER * SS, fill=255
    )
    front = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    paint(front, front_mask, FRONT_TOP, FRONT_BOTTOM, FRONT_BODY[1], FRONT_BODY[3])
    art.alpha_composite(front)

    graph = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    draw = ImageDraw.Draw(graph)
    stroke(
        draw,
        [(TRUNK_X * SS, TRUNK_TOP * SS), (TRUNK_X * SS, TRUNK_BOTTOM * SS)],
        STROKE,
        GIT_ORANGE,
    )
    stroke(
        draw,
        bezier(
            (TRUNK_X, BRANCH_FROM_Y),
            (TRUNK_X, BRANCH_FROM_Y - 62),
            (TRUNK_X + 118, BRANCH_NODE[1]),
            BRANCH_NODE,
        ),
        STROKE,
        GIT_ORANGE,
    )
    node(draw, (TRUNK_X, TRUNK_TOP), GIT_ORANGE)
    node(draw, (TRUNK_X, TRUNK_BOTTOM), GIT_ORANGE)
    node(draw, BRANCH_NODE, GIT_ORANGE_DEEP)
    art.alpha_composite(graph)

    return art


def fit(art, coverage):
    """Centres the mark on a transparent 1024 canvas at the given coverage."""
    box = art.getbbox()
    cropped = art.crop(box)
    target = round(GRID * coverage)
    scale = target / max(cropped.size)
    size = (max(1, round(cropped.width * scale)), max(1, round(cropped.height * scale)))
    canvas = Image.new("RGBA", (GRID, GRID), (0, 0, 0, 0))
    canvas.paste(
        cropped.resize(size, Image.LANCZOS),
        ((GRID - size[0]) // 2, (GRID - size[1]) // 2),
    )
    return canvas


def background(radius):
    bg = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    mask = Image.new("L", (S, S), 255)
    if radius:
        mask = Image.new("L", (S, S), 0)
        ImageDraw.Draw(mask).rounded_rectangle(
            [0, 0, S - 1, S - 1], radius=round(radius * SS), fill=255
        )
    paint(bg, mask, BG_TOP, BG_BOTTOM, 0, GRID)
    return bg.resize((GRID, GRID), Image.LANCZOS)


def main():
    out = Path(__file__).resolve().parent.parent / "assets" / "icon"
    out.mkdir(parents=True, exist_ok=True)

    art = render_art()
    mark = fit(art, 0.78)

    # Full-bleed square: iOS and Windows mask or frame it themselves.
    square = background(0)
    square.alpha_composite(mark)
    square.convert("RGB").save(out / "app_icon.png")

    # Rounded, for surfaces that show the icon unmasked (Linux, Android legacy).
    rounded = background(200)
    rounded.alpha_composite(mark)
    rounded.save(out / "app_icon_rounded.png")

    # macOS draws icons unmasked and expects breathing room in the canvas.
    macos = Image.new("RGBA", (GRID, GRID), (0, 0, 0, 0))
    inset = round(GRID * 0.08)
    plate = background(200).resize((GRID - 2 * inset, GRID - 2 * inset), Image.LANCZOS)
    plate.alpha_composite(fit(art, 0.78).resize(plate.size, Image.LANCZOS))
    macos.paste(plate, (inset, inset))
    macos.save(out / "app_icon_macos.png")

    # Android adaptive foreground: the mark alone. flutter_launcher_icons insets
    # this by a further 16%, and a circular mask only clears 66% of the canvas,
    # so the mark is sized to keep its corners inside that circle.
    fit(art, 0.78).save(out / "app_icon_foreground.png")

    # Windows wants every launcher size in the one .ico; flutter_launcher_icons
    # emits 256 alone, which Windows then downscales badly for the taskbar.
    ico = out.parent.parent / "windows" / "runner" / "resources" / "app_icon.ico"
    sizes = [16, 24, 32, 48, 64, 128, 256]
    rounded.save(ico, sizes=[(s, s) for s in sizes])

    # Web: the plain icons are shown as-is, while maskable ones get cropped to
    # whatever shape the platform likes, so the mark shrinks to clear a circle.
    web = out.parent.parent / "web"
    maskable = background(0)
    maskable.alpha_composite(fit(art, 0.60))
    for size in (192, 512):
        rounded.resize((size, size), Image.LANCZOS).save(
            web / "icons" / f"Icon-{size}.png"
        )
        maskable.resize((size, size), Image.LANCZOS).save(
            web / "icons" / f"Icon-maskable-{size}.png"
        )
    rounded.resize((32, 32), Image.LANCZOS).save(web / "favicon.png")

    print(f"wrote 4 masters to {out}")
    print(f"wrote {ico}")
    print(f"wrote web icons and favicon under {web}")


if __name__ == "__main__":
    main()
