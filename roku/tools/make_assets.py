# Generates the Roku app's images from the Flutter app's assets.
#   python roku/tools/make_assets.py        (from the repo root)
# Everything drawn here is white so the app can tint it with blendColor.
import math, os, shutil
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
APP = os.path.join(ROOT, 'roku', 'app')
IMG = os.path.join(APP, 'images')
FLUTTER = os.path.expanduser('~/fvm/versions/3.47.5/bin/cache/artifacts/material_fonts')
os.makedirs(os.path.join(IMG, 'icons'), exist_ok=True)
os.makedirs(os.path.join(APP, 'fonts'), exist_ok=True)

WHITE = (255, 255, 255, 255)
SS = 4  # supersampling for smooth edges

# Material icons used by the app (codepoints from Flutter's icons.dart).
ICONS = {
    'basketball': 0xe5e6, 'soccer': 0xe5f2, 'football': 0xe5e9, 'hockey': 0xe5ec,
    'baseball': 0xe5e5, 'motorsports': 0xe5ef, 'mma': 0xe5ee, 'tennis': 0xe5f3,
    'rugby': 0xe5f0, 'golf': 0xe5ea, 'cricket': 0xe5e7, 'adjust': 0xe061,
    'track_changes': 0xe673, 'sports': 0xe5e3, 'live_tv': 0xe387,
    'fire': 0xe392, 'favorite': 0xe25b, 'settings': 0xe57f, 'visibility': 0xe6bd,
    'wifi_find': 0xf05a8,
}


def icon(name, cp, size=96):
    font = ImageFont.truetype(os.path.join(FLUTTER, 'materialicons-regular.otf'), size * SS)
    im = Image.new('RGBA', (size * SS, size * SS), (0, 0, 0, 0))
    ImageDraw.Draw(im).text((0, 0), chr(cp), font=font, fill=WHITE)
    im.resize((size, size), Image.LANCZOS).save(os.path.join(IMG, 'icons', name + '.png'))


def nine_patch(name, radius, stroke=None):
    """A white rounded rectangle as a 9-patch: the 1px black marks on the top
    and left edges say which row/column may stretch."""
    core = radius * 2 + 2
    big = Image.new('RGBA', (core * SS, core * SS), (0, 0, 0, 0))
    d = ImageDraw.Draw(big)
    if stroke:
        d.rounded_rectangle((0, 0, core * SS - 1, core * SS - 1), radius=radius * SS, outline=WHITE, width=stroke * SS)
    else:
        d.rounded_rectangle((0, 0, core * SS - 1, core * SS - 1), radius=radius * SS, fill=WHITE)
    body = big.resize((core, core), Image.LANCZOS)
    im = Image.new('RGBA', (core + 2, core + 2), (0, 0, 0, 0))
    im.paste(body, (1, 1))
    mark = (0, 0, 0, 255)
    for i in (radius + 1, radius + 2):  # the stretchable middle
        im.putpixel((i, 0), mark)
        im.putpixel((0, i), mark)
    # Content area = the whole image (right and bottom marks). Without these,
    # Roku lists map only the stretchable middle onto an item and draw the
    # corners outside it, so focus rings spill ~20px onto the neighbours.
    for i in range(1, core + 1):
        im.putpixel((core + 1, i), mark)
        im.putpixel((i, core + 1), mark)
    im.save(os.path.join(IMG, name + '.9.png'))


def disc(name, size=128):
    big = Image.new('RGBA', (size * SS, size * SS), (0, 0, 0, 0))
    ImageDraw.Draw(big).ellipse((0, 0, size * SS - 1, size * SS - 1), fill=WHITE)
    big.resize((size, size), Image.LANCZOS).save(os.path.join(IMG, name + '.png'))


def spinner(name, size=72, stroke=7):
    """A three-quarter ring for BusySpinner to turn, like the phone app's
    progress indicator. Drawn at the size it's shown: BusySpinner turns the
    image about its own centre."""
    s, w = size * SS, stroke * SS
    big = Image.new('RGBA', (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(big)
    d.arc((0, 0, s - 1, s - 1), start=-90, end=180, fill=WHITE, width=w)
    r, c = (s - w) / 2, s / 2          # round caps at both ends
    for ang in (-90, 180):
        x, y = c + r * math.cos(math.radians(ang)), c + r * math.sin(math.radians(ang))
        d.ellipse((x - w / 2, y - w / 2, x + w / 2, y + w / 2), fill=WHITE)
    big.resize((size, size), Image.LANCZOS).save(os.path.join(IMG, name + '.png'))


def brand():
    """Home-screen tile and splash: the ball plus a letter-spaced wordmark."""
    fg = Image.open(os.path.join(ROOT, 'assets', 'icon', 'app_icon_foreground.png')).convert('RGBA')
    font_path = os.path.join(ROOT, 'assets', 'fonts', 'BarlowSemiCondensed-SemiBold.ttf')

    def card(w, h, ball_frac, text_size, gap):
        im = Image.new('RGBA', (w, h), (0x22, 0x25, 0x2A, 255))
        d = ImageDraw.Draw(im)
        font = ImageFont.truetype(font_path, text_size)
        spacing = text_size * 0.04
        widths = [d.textlength(ch, font=font) for ch in 'SPORTS']
        b = int(h * ball_frac)
        ball = fg.resize((b, b), Image.LANCZOS)
        asc, _ = font.getmetrics()
        cap = text_size * 0.7
        x0 = int((w - (b + gap + sum(widths) + spacing * 5)) / 2)
        im.alpha_composite(ball, (x0, (h - b) // 2))
        x, y = x0 + b + gap, h / 2 - (asc - cap / 2)
        for ch, cw in zip('SPORTS', widths):
            d.text((x, y), ch, font=font, fill=(0xE7, 0xE9, 0xEE, 255))
            x += cw + spacing
        return im.convert('RGB')

    card(540, 405, 0.30, 92, 22).save(os.path.join(IMG, 'icon_fhd.png'))
    card(290, 218, 0.30, 49, 12).save(os.path.join(IMG, 'icon_hd.png'))
    card(1920, 1080, 0.16, 150, 44).save(os.path.join(IMG, 'splash_fhd.png'))


for n, cp in ICONS.items():
    icon(n, cp)
nine_patch('card', 20)        # list rows, tiles, cards
nine_patch('chip', 10)        # HD/SD badges, small pills
nine_patch('ring', 22, 4)     # focus outline, drawn over a card
disc('disc')                  # badge backgrounds, live dot
spinner('spinner')            # loading
brand()
for f in ('BarlowSemiCondensed-Regular.ttf', 'BarlowSemiCondensed-Medium.ttf', 'BarlowSemiCondensed-SemiBold.ttf', 'BarlowSemiCondensed-Bold.ttf', 'OFL.txt'):
    shutil.copy(os.path.join(ROOT, 'assets', 'fonts', f), os.path.join(APP, 'fonts', f))
for f in ('roboto-regular.ttf', 'roboto-medium.ttf', 'roboto_license.txt'):
    shutil.copy(os.path.join(FLUTTER, f), os.path.join(APP, 'fonts', f))
print('assets written to', IMG)
