"""Генерация значка Cash («Кошелёк») для Windows (.ico) и Android (legacy + adaptive).

Запуск: python make_icon.py <папка_вывода>
Рисует через Pillow с суперсэмплингом, без внешних SVG-рендереров.
"""
import os
import sys
from PIL import Image, ImageDraw

BG = (0x2B, 0x3A, 0x67)
CARD = (0x8F, 0xD3, 0xC7)
STRIPE = (0x5F, 0xB3, 0xA6)
WALLET = (0xF4, 0xA2, 0x59)
CLASP = (0xE0, 0x8A, 0x3C)

# Фигуры в «единицах содержимого» 0..100 (центр ~50,50).
SHAPES = [
    ("rect", (23, 21, 71, 51), 4, CARD),
    ("rect", (23, 28, 71, 33), 0, STRIPE),
    ("rect", (15, 37, 81, 79), 8, WALLET),
    ("rect", (56, 49, 85, 67), 6, CLASP),
    ("circle", (66, 58), 3.4, BG),
]

SS = 4  # суперсэмплинг


def draw_content(draw, ox, oy, scale):
    for kind, geom, r, color in SHAPES:
        if kind == "rect":
            x0, y0, x1, y1 = geom
            box = [ox + x0 * scale, oy + y0 * scale, ox + x1 * scale, oy + y1 * scale]
            draw.rounded_rectangle(box, radius=r * scale, fill=color)
        else:
            cx, cy = geom
            rr = r * scale
            draw.ellipse([ox + cx * scale - rr, oy + cy * scale - rr,
                          ox + cx * scale + rr, oy + cy * scale + rr], fill=color)


def full_icon(size, corner=0.225, content=0.80):
    """Значок целиком: скруглённый квадрат + кошелёк, прозрачные углы."""
    S = size * SS
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([0, 0, S - 1, S - 1], radius=S * corner, fill=BG)
    scale = S * content / 100
    off = (S - 100 * scale) / 2
    draw_content(d, off, off, scale)
    return img.resize((size, size), Image.LANCZOS)


def adaptive_foreground(size, content=70 / 108):
    """Передний слой adaptive icon (108dp, видимая зона ~72dp)."""
    S = size * SS
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    scale = S * content / 100
    off = (S - 100 * scale) / 2
    draw_content(d, off, off, scale)
    return img.resize((size, size), Image.LANCZOS)


def main(out):
    os.makedirs(out, exist_ok=True)
    # Мастер-изображение
    full_icon(1024).save(os.path.join(out, "cash-icon-1024.png"))

    # Windows .ico
    win = os.path.join(out, "windows/runner/resources")
    os.makedirs(win, exist_ok=True)
    sizes = [16, 20, 24, 32, 40, 48, 64, 128, 256]
    big = full_icon(256)
    frames = {s: full_icon(s) for s in sizes}
    big.save(os.path.join(win, "app_icon.ico"), format="ICO",
             sizes=[(s, s) for s in sizes], append_images=[frames[s] for s in sizes if s != 256])

    # Android
    res = os.path.join(out, "android/app/src/main/res")
    dens = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}
    for name, k in dens.items():
        d = os.path.join(res, f"mipmap-{name}")
        os.makedirs(d, exist_ok=True)
        # legacy (Android < 8): 48dp, небольшой отступ как у стандартных значков
        leg = Image.new("RGBA", (int(48 * k),) * 2, (0, 0, 0, 0))
        inner = full_icon(int(44 * k))
        leg.paste(inner, (int(2 * k), int(2 * k)), inner)
        leg.save(os.path.join(d, "ic_launcher.png"))
        adaptive_foreground(int(108 * k)).save(os.path.join(d, "ic_launcher_foreground.png"))

    anydpi = os.path.join(res, "mipmap-anydpi-v26")
    os.makedirs(anydpi, exist_ok=True)
    xml = ('<?xml version="1.0" encoding="utf-8"?>\n'
           '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
           '    <background android:drawable="@color/ic_launcher_background"/>\n'
           '    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n'
           '</adaptive-icon>\n')
    with open(os.path.join(anydpi, "ic_launcher.xml"), "w", encoding="utf-8") as f:
        f.write(xml)
    vals = os.path.join(res, "values")
    os.makedirs(vals, exist_ok=True)
    with open(os.path.join(vals, "ic_launcher_background.xml"), "w", encoding="utf-8") as f:
        f.write('<?xml version="1.0" encoding="utf-8"?>\n<resources>\n'
                '    <color name="ic_launcher_background">#2B3A67</color>\n</resources>\n')


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "out")
