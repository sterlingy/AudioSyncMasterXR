# Adds the title and promo lines to the hero render.
# python add_title.py  (reads/writes docs/images, run from the project root)
from PIL import Image, ImageDraw, ImageFilter, ImageFont

SRC = "docs/images/hero_1920x1080.png"
OUT = "docs/images/hero_1920x1080_title"
FONT = r"C:\Windows\Fonts\bahnschrift.ttf"

TITLE = "AudioSyncMaster"
TAGLINE = "Jam together in XR, wherever you are."
FEATURES = "SIX BUILT-IN SYNTHS   \u2022   SPATIAL AUDIO   \u2022   EVERY PLAYER IN TIME"


def font(size, style):
    f = ImageFont.truetype(FONT, size)
    f.set_variation_by_name(style)
    return f


def spaced(draw, xy_center, text, f, spacing, fill):
    """Draws text centred on x with extra letter spacing; returns nothing."""
    widths = [draw.textlength(ch, font=f) for ch in text]
    total = sum(widths) + spacing * (len(text) - 1)
    x = xy_center[0] - total / 2
    for ch, w in zip(text, widths):
        draw.text((x, xy_center[1]), ch, font=f, fill=fill, anchor="ls")
        x += w + spacing


img = Image.open(SRC).convert("RGB")
W, H = img.size

# darken the top and bottom bands a little so the text reads
shade = Image.new("L", (W, H), 0)
sd = ImageDraw.Draw(shade)
for y in range(260):
    sd.line([(0, y), (W, y)], fill=int(150 * (1 - y / 260) ** 1.6))
for y in range(H - 190, H):
    sd.line([(0, y), (W, y)], fill=int(170 * ((y - (H - 190)) / 190) ** 1.4))
img = Image.composite(Image.new("RGB", (W, H), (4, 6, 14)), img, shade)

title_f = font(100, "Bold")
tag_f = font(36, "Light")
feat_f = font(25, "SemiBold")

# glow layer behind the title
glow = Image.new("RGB", (W, H), (0, 0, 0))
gd = ImageDraw.Draw(glow)
spaced(gd, (W / 2, 112), TITLE, title_f, 6, (90, 170, 255))
glow = glow.filter(ImageFilter.GaussianBlur(18))
img = Image.blend(img, Image.composite(glow, img, glow.convert("L").point(lambda v: min(255, v * 3))), 0.85)

d = ImageDraw.Draw(img)
spaced(d, (W / 2, 112), TITLE, title_f, 6, (244, 248, 255))
d.text((W / 2, 163), TAGLINE, font=tag_f, fill=(190, 215, 255), anchor="ms")
spaced(d, (W / 2, H - 52), FEATURES, feat_f, 3, (215, 225, 245))


# --- "BYO Voice and Instruments" badge: a neon sticker in the instruments' colours
BADGE_POS = (1640, 218)   # centre on the image
BADGE_TILT = 6            # degrees, counter-clockwise
RAINBOW = [(150, 235, 110), (60, 215, 205), (255, 205, 85), (255, 140, 60), (255, 85, 160), (155, 120, 255)]


def gradient(size, stops):
    """Horizontal gradient through the given colours."""
    w, h = size
    g = Image.new("RGB", (w, 1))
    for x in range(w):
        t = x / max(1, w - 1) * (len(stops) - 1)
        i = min(int(t), len(stops) - 2)
        f = t - i
        a, b = stops[i], stops[i + 1]
        g.putpixel((x, 0), tuple(int(a[k] + (b[k] - a[k]) * f) for k in range(3)))
    return g.resize((w, h))


def badge():
    S = 2  # supersample
    byo_f = font(80 * S, "Bold")
    l1 = font(34 * S, "SemiBold")
    l2 = font(25 * S, "SemiBold")
    m = ImageDraw.Draw(Image.new("L", (1, 1)))
    byo_w = m.textlength("BYO", font=byo_f)
    txt_w = max(m.textlength("VOICE AND", font=l1), sum(m.textlength(c, font=l2) + 2.4 * S for c in "INSTRUMENTS"))
    W2, H2 = int(22 * S + byo_w + 16 * S + 8 * 9 * S + 12 * S + txt_w + 26 * S), 118 * S
    pad = 40 * S
    cw, ch = W2 + 2 * pad, H2 + 2 * pad
    grad = gradient((cw, ch), RAINBOW)
    box = (pad, pad, pad + W2, pad + H2)
    rad = 26 * S

    out = Image.new("RGBA", (cw, ch), (0, 0, 0, 0))
    # dark glass body
    body = Image.new("L", (cw, ch), 0)
    ImageDraw.Draw(body).rounded_rectangle(box, rad, fill=215)
    out.paste(Image.new("RGBA", (cw, ch), (7, 9, 20, 255)), (0, 0), body)
    # neon outline + glow
    ring = Image.new("L", (cw, ch), 0)
    ImageDraw.Draw(ring).rounded_rectangle(box, rad, outline=255, width=3 * S)
    glow = ring.filter(ImageFilter.GaussianBlur(9 * S)).point(lambda v: min(255, v * 4))
    out = Image.alpha_composite(out, Image.merge("RGBA", (*grad.split(), glow.point(lambda v: v * 0.8))))
    out.paste(grad, (0, 0), ring)

    d = ImageDraw.Draw(out)
    # "BYO" in the gradient, with its own glow
    tx, ty = pad + 22 * S, pad + H2 // 2
    tmask = Image.new("L", (cw, ch), 0)
    ImageDraw.Draw(tmask).text((tx, ty), "BYO", font=byo_f, fill=255, anchor="lm")
    tglow = tmask.filter(ImageFilter.GaussianBlur(7 * S)).point(lambda v: v * 0.7)
    out = Image.alpha_composite(out, Image.merge("RGBA", (*grad.split(), tglow)))
    out.paste(grad, (0, 0), tmask)

    # a little voice waveform as the divider
    d = ImageDraw.Draw(out)
    wx = tx + byo_w + 16 * S
    heights = [0.25, 0.55, 0.9, 0.6, 1.0, 0.45, 0.75, 0.3]
    bars = Image.new("L", (cw, ch), 0)
    bd = ImageDraw.Draw(bars)
    for i, hgt in enumerate(heights):
        x = wx + i * 9 * S
        half = hgt * 34 * S
        bd.rounded_rectangle((x, ty - half, x + 4 * S, ty + half), 2 * S, fill=255)
    out = Image.alpha_composite(out, Image.merge("RGBA", (*grad.split(), bars.filter(ImageFilter.GaussianBlur(5 * S)).point(lambda v: v * 0.6))))
    out.paste(grad, (0, 0), bars)

    # two lines of text
    d = ImageDraw.Draw(out)
    lx = wx + len(heights) * 9 * S + 12 * S
    d.text((lx, ty - 4 * S), "VOICE AND", font=l1, fill=(240, 245, 255, 255), anchor="ls")
    spaced_rgba(d, lx, ty + 30 * S, "INSTRUMENTS", l2, 2.4 * S, (190, 205, 235, 255))

    out = out.rotate(BADGE_TILT, resample=Image.BICUBIC, expand=True)
    return out.resize((out.width // S, out.height // S), Image.LANCZOS)


def spaced_rgba(draw, x, y, text, f, spacing, fill):
    for ch in text:
        draw.text((x, y), ch, font=f, fill=fill, anchor="ls")
        x += draw.textlength(ch, font=f) + spacing


b = badge()
img = img.convert("RGBA")
img.alpha_composite(b, (int(BADGE_POS[0] - b.width / 2), int(BADGE_POS[1] - b.height / 2)))
img = img.convert("RGB")

img.save(OUT + ".png", optimize=True)
img.save(OUT + ".jpg", quality=92, optimize=True, progressive=True)
print("saved", OUT, img.size)
