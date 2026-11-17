#!/usr/bin/env python3
"""从两张源图生成各平台图标。

手机图标 -> Android（含自适应图标、电视横幅）、iOS
电脑图标 -> Windows（ico）、macOS

用法：
  python3 scripts/generate_app_icons.py --phone 手机图标.png --desktop 电脑图标.png
不带参数时读 scripts/brand/ 下的同名文件。
"""
import argparse
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
BRAND = ROOT / 'scripts' / 'brand'
FONT = '/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc'
FALLBACK_FONT = '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc'
CANVAS = 1024
SAFE_ZONE = 0.66


def load(path: Path) -> Image.Image:
    image = Image.open(path).convert('RGBA')
    side = min(image.size)
    left = (image.width - side) // 2
    top = (image.height - side) // 2
    return image.crop((left, top, left + side, top + side)).resize(
        (CANVAS, CANVAS), Image.Resampling.LANCZOS
    )


def rounded(image: Image.Image, ratio: float = 0.225) -> Image.Image:
    mask = Image.new('L', image.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, image.width - 1, image.height - 1),
        radius=int(image.width * ratio),
        fill=255,
    )
    out = image.copy()
    out.putalpha(mask)
    return out


def corner_color(image: Image.Image) -> tuple[int, int, int]:
    pixels = [image.getpixel((4, 4)), image.getpixel((image.width - 5, 4))]
    red = sum(p[0] for p in pixels) // len(pixels)
    green = sum(p[1] for p in pixels) // len(pixels)
    blue = sum(p[2] for p in pixels) // len(pixels)
    return red, green, blue


def adaptive_foreground(image: Image.Image) -> Image.Image:
    """前景铺满画布，让启动器自己裁形状，避免出现「圆角套圆角」。"""
    return image.resize((CANVAS, CANVAS), Image.Resampling.LANCZOS)


def monochrome(image: Image.Image) -> Image.Image:
    """亮部保留成白色剪影，给 Android 13 主题图标用。"""
    canvas = Image.new('RGBA', (CANVAS, CANVAS), (0, 0, 0, 0))
    side = int(CANVAS * SAFE_ZONE)
    art = image.resize((side, side), Image.Resampling.LANCZOS)
    grey = art.convert('L')
    mask = grey.point(lambda value: 0 if value < 70 else min(255, (value - 70) * 3))
    shape = Image.new('RGBA', art.size, (255, 255, 255, 255))
    shape.putalpha(mask)
    offset = (CANVAS - side) // 2
    canvas.paste(shape, (offset, offset), shape)
    return canvas


def font(size: int) -> ImageFont.FreeTypeFont:
    path = FONT if Path(FONT).exists() else FALLBACK_FONT
    return ImageFont.truetype(path, size)


def banner(icon: Image.Image, name: str) -> Image.Image:
    width, height = 640, 360
    image = Image.new('RGB', (width, height))
    draw = ImageDraw.Draw(image)
    for y in range(height):
        ratio = y / height
        draw.line(
            [(0, y), (width, y)],
            fill=(
                int(10 + 12 * ratio),
                int(10 + 10 * ratio),
                int(26 + 40 * ratio),
            ),
        )
    badge = icon.resize((196, 196), Image.Resampling.LANCZOS)
    image.paste(badge, (64, (height - 196) // 2), badge)
    title = font(92)
    box = draw.textbbox((0, 0), name, font=title)
    draw.text(
        (300, (height - (box[3] - box[1])) / 2 - box[1]),
        name,
        font=title,
        fill=(245, 246, 255),
    )
    return image


def save(image: Image.Image, relative: str, output: Path) -> None:
    target = output / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    image.save(target)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--phone', type=Path, default=BRAND / 'phone.png')
    parser.add_argument('--desktop', type=Path, default=BRAND / 'desktop.png')
    parser.add_argument('--name', default='影屿')
    parser.add_argument('--output', type=Path, default=ROOT)
    options = parser.parse_args()
    output = options.output

    phone = load(options.phone)
    desktop = load(options.desktop)
    phone_rounded = rounded(phone)
    desktop_rounded = rounded(desktop)
    phone_rgb = phone_rounded.convert('RGB')

    # iOS：不透明方图
    contents = json.loads(
        (ROOT / 'ios/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json').read_text()
    )
    for entry in contents['images']:
        if 'filename' not in entry:
            continue
        size = round(float(entry['size'].split('x')[0]) * float(entry['scale'].rstrip('x')))
        save(
            phone_rgb.resize((size, size), Image.Resampling.LANCZOS),
            'ios/Runner/Assets.xcassets/AppIcon.appiconset/' + entry['filename'],
            output,
        )

    # Windows：ico，多尺寸
    desktop_rounded.resize((256, 256), Image.Resampling.LANCZOS).save(
        output / 'windows/runner/resources/app_icon.ico',
        sizes=[(256, 256), (128, 128), (64, 64), (48, 48), (32, 32), (16, 16)],
    )

    # macOS：圆角留白方图
    macos_canvas = Image.new('RGBA', (CANVAS, CANVAS), (0, 0, 0, 0))
    macos_badge = desktop_rounded.resize((824, 824), Image.Resampling.LANCZOS)
    macos_canvas.paste(macos_badge, (100, 100), macos_badge)
    macos_contents = json.loads(
        (ROOT / 'macos/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json').read_text()
    )
    for entry in macos_contents['images']:
        if 'filename' not in entry:
            continue
        size = round(float(entry['size'].split('x')[0]) * float(entry['scale'].rstrip('x')))
        save(
            macos_canvas.resize((size, size), Image.Resampling.LANCZOS),
            'macos/Runner/Assets.xcassets/AppIcon.appiconset/' + entry['filename'],
            output,
        )

    # Android：旧版图标 + 自适应图标三层
    adaptive = adaptive_foreground(phone)
    for density, scale in [
        ('mdpi', 1),
        ('hdpi', 1.5),
        ('xhdpi', 2),
        ('xxhdpi', 3),
        ('xxxhdpi', 4),
    ]:
        legacy = round(48 * scale)
        layer = round(108 * scale)
        save(
            phone_rounded.resize((legacy, legacy), Image.Resampling.LANCZOS),
            f'android/app/src/main/res/mipmap-{density}/ic_launcher.png',
            output,
        )
        save(
            adaptive.resize((layer, layer), Image.Resampling.LANCZOS),
            f'android/app/src/main/res/mipmap-{density}/ic_launcher_foreground.png',
            output,
        )

    red, green, blue = corner_color(phone)
    (output / 'android/app/src/main/res/values/ic_launcher_background.xml').write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<resources>\n'
        f'    <color name="ic_launcher_background">#{red:02X}{green:02X}{blue:02X}</color>\n'
        '</resources>\n',
        encoding='utf-8',
    )

    save(banner(phone_rounded, options.name), 'android/app/src/main/res/drawable-xhdpi/tv_banner.png', output)
    print('图标已生成')


if __name__ == '__main__':
    main()
