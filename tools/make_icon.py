#!/usr/bin/env python3
"""Generate an original opaque app icon from vector geometry; needs Pillow."""
from pathlib import Path
import json
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "App/Resources/Assets.xcassets"


def bezier(points, count=80):
    result = []
    for n in range(count + 1):
        t = n / count
        u = 1 - t
        result.append((u**3 * points[0][0] + 3*u*u*t * points[1][0] + 3*u*t*t * points[2][0] + t**3 * points[3][0], u**3 * points[0][1] + 3*u*u*t * points[1][1] + 3*u*t*t * points[2][1] + t**3 * points[3][1]))
    return result


def main():
    folder = ASSETS / "AppIcon.appiconset"
    folder.mkdir(parents=True, exist_ok=True)
    image = Image.new("RGB", (1024, 1024), "#185B4B")
    draw = ImageDraw.Draw(image)
    for y in range(1024):
        draw.line((0, y, 1024, y), fill=(24 + int(y/1024*6), 91 - int(y/1024*14), 75 - int(y/1024*10)))
    draw.rounded_rectangle((169, 162, 855, 864), radius=168, outline="#528A72", width=3)
    leaf = bezier([(497, 620), (275, 461), (360, 267), (723, 256)]) + bezier([(723, 256), (734, 488), (669, 653), (497, 620)])
    draw.polygon(leaf, fill="#E5EEDB")
    draw.line(bezier([(443, 690), (469, 535), (557, 411), (666, 326)]), fill="#185B4B", width=23)
    draw.line(bezier([(276, 719), (383, 701), (435, 717), (512, 751)]), fill="#E6C891", width=25)
    draw.line(bezier([(512, 751), (592, 716), (650, 701), (748, 719)]), fill="#E6C891", width=25)
    draw.line((512, 751, 512, 801), fill="#E6C891", width=22)
    image.save(folder / "AppIcon.png", optimize=True)
    (folder / "Contents.json").write_text(json.dumps({"images": [{"filename": "AppIcon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}], "info": {"author": "xcode", "version": 1}}, indent=2), encoding="utf-8")
    (ASSETS / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}), encoding="utf-8")
    accent = ASSETS / "AccentColor.colorset"
    accent.mkdir(exist_ok=True)
    (accent / "Contents.json").write_text(json.dumps({"colors": [{"color": {"color-space": "srgb", "components": {"alpha": "1.000", "red": "0.130", "green": "0.430", "blue": "0.360"}}, "idiom": "universal"}, {"appearances": [{"appearance": "luminosity", "value": "dark"}], "color": {"color-space": "srgb", "components": {"alpha": "1.000", "red": "0.550", "green": "0.820", "blue": "0.710"}}, "idiom": "universal"}], "info": {"author": "xcode", "version": 1}}, indent=2), encoding="utf-8")
    print("Generated original 1024px RGB app icon and dynamic accent asset")


if __name__ == "__main__":
    main()
