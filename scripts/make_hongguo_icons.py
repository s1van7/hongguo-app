#!/usr/bin/env python3
"""生成红果影视的 Android 图标：红色圆角底 + 白色「果」字。"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
RES = ROOT / 'android' / 'app' / 'src' / 'main' / 'res'
FONT = '/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc'
FALLBACK = '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc'
GLYPH = '果'
RED = (232, 64, 42, 255)
RED_DARK = (196, 38, 28, 255)

LEGACY = {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192}
FOREGROUND = {'mdpi': 108, 'hdpi': 162, 'xhdpi': 216, 'xxhdpi': 324, 'xxxhdpi': 432}


def font(size: int) -> ImageFont.FreeTypeFont:
    path = FONT if Path(FONT).exists() else FALLBACK
    return ImageFont.truetype(path, size)


def draw_glyph(image: Image.Image, size: int, scale: float) -> None:
    draw = ImageDraw.Draw(image)
    box = int(size * scale)
    f = font(box)
    left, top, right, bottom = draw.textbbox((0, 0), GLYPH, font=f)
    draw.text(
        ((size - (right - left)) / 2 - left, (size - (bottom - top)) / 2 - top),
        GLYPH,
        font=f,
        fill=(255, 255, 255, 255),
    )


def legacy_icon(size: int) -> Image.Image:
    image = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    gradient = Image.new('RGBA', (size, size))
    pen = ImageDraw.Draw(gradient)
    for y in range(size):
        t = y / max(1, size - 1)
        pen.line(
            [(0, y), (size, y)],
            fill=tuple(round(RED[i] * (1 - t) + RED_DARK[i] * t) for i in range(4)),
        )
    mask = Image.new('L', (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, size - 1, size - 1], radius=int(size * 0.22), fill=255
    )
    image.paste(gradient, (0, 0), mask)
    draw_glyph(image, size, 0.56)
    return image


def foreground(size: int) -> Image.Image:
    image = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    draw_glyph(image, size, 0.40)
    return image


def monochrome(size: int) -> Image.Image:
    image = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    draw_glyph(image, size, 0.40)
    return image


for density, size in LEGACY.items():
    target = RES / f'mipmap-{density}'
    target.mkdir(parents=True, exist_ok=True)
    legacy_icon(size).save(target / 'ic_launcher.png')
    foreground(FOREGROUND[density]).save(target / 'ic_launcher_foreground.png')
    monochrome(FOREGROUND[density]).save(target / 'ic_launcher_monochrome.png')
    print(f'{density}: {size}px')

color_file = RES / 'values' / 'ic_launcher_background.xml'
color_file.write_text(
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<resources>\n'
    '    <color name="ic_launcher_background">#E8402A</color>\n'
    '</resources>\n',
    encoding='utf-8',
)
print('背景色已更新')
