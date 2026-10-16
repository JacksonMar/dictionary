# Генерує App/Resources/Assets.xcassets/AppIcon.appiconset (потрібен Pillow):
#   python3 scripts/make_icon.py App/Resources/Assets.xcassets/AppIcon.appiconset /tmp/icon-preview.png
import sys, os, json
from PIL import Image, ImageDraw, ImageFont, ImageFilter

S = 4096  # supersampled canvas (4x of 1024)
k = S / 1024

def lerp(a, b, t): return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

# --- background squircle (macOS grid: 824pt body, 100pt margin) ---
img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
margin, body, radius = 100 * k, 824 * k, 185 * k
top, bottom = (59, 130, 246), (29, 64, 175)
grad = Image.new("RGBA", (S, S))
gd = ImageDraw.Draw(grad)
for y in range(S):
    t = min(max((y - margin) / body, 0), 1)
    gd.line([(0, y), (S, y)], fill=lerp(top, bottom, t) + (255,))
mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle([margin, margin, margin + body, margin + body], radius=radius, fill=255)

# soft drop shadow under the squircle
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(shadow).rounded_rectangle([margin, margin + 14 * k, margin + body, margin + body + 14 * k], radius=radius, fill=(0, 0, 0, 90))
shadow = shadow.filter(ImageFilter.GaussianBlur(18 * k))
img.alpha_composite(shadow)
img.paste(grad, (0, 0), mask)

d = ImageDraw.Draw(img)

# --- open book ---
cx = S / 2
bw, bh = 300 * k, 380 * k          # one page
by = 330 * k                        # top of pages
gap = 14 * k
page = (255, 255, 255, 255)
# book shadow
bs = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(bs).rounded_rectangle([cx - bw - gap, by + 24 * k, cx + bw + gap, by + bh + 34 * k], radius=36 * k, fill=(10, 25, 80, 110))
bs = bs.filter(ImageFilter.GaussianBlur(16 * k))
img.alpha_composite(bs)
d = ImageDraw.Draw(img)
# pages (slightly curved feel: rounded outer corners)
d.rounded_rectangle([cx - bw - gap, by, cx - gap, by + bh], radius=34 * k, fill=page)
d.rounded_rectangle([cx + gap, by, cx + bw + gap, by + bh], radius=34 * k, fill=page)
# spine
d.rectangle([cx - gap, by + 18 * k, cx + gap, by + bh - 4 * k], fill=(219, 228, 245, 255))

# yellow bookmark ribbon on right page
rx = cx + bw - 70 * k
ribbon = [(rx, by - 10 * k), (rx + 64 * k, by - 10 * k), (rx + 64 * k, by + 150 * k), (rx + 32 * k, by + 118 * k), (rx, by + 150 * k)]
d.polygon(ribbon, fill=(250, 204, 21, 255))

# letters
font_path = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
f = ImageFont.truetype(font_path, int(230 * k))
blue = (30, 64, 175, 255)
def center_text(text, x_center, y_center, fill):
    l, t, r, b = d.textbbox((0, 0), text, font=f)
    d.text((x_center - (r - l) / 2 - l, y_center - (b - t) / 2 - t), text, font=f, fill=fill)
center_text("A", cx - gap - bw / 2, by + bh / 2 + 10 * k, blue)
center_text("Я", cx + gap + bw / 2 - 10 * k, by + bh / 2 + 10 * k, (37, 99, 235, 255))

# small arrow under the book: "A → Я"
ay = by + bh + 95 * k
d.line([(cx - 120 * k, ay), (cx + 95 * k, ay)], fill=(255, 255, 255, 235), width=int(26 * k))
d.polygon([(cx + 140 * k, ay), (cx + 80 * k, ay - 45 * k), (cx + 80 * k, ay + 45 * k)], fill=(255, 255, 255, 235))

out_dir = sys.argv[1]
os.makedirs(out_dir, exist_ok=True)
master = img.resize((1024, 1024), Image.LANCZOS)
entries = []
for pt in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        px = pt * scale
        name = f"icon_{pt}x{pt}{'@2x' if scale == 2 else ''}.png"
        master.resize((px, px), Image.LANCZOS).save(os.path.join(out_dir, name))
        entries.append({"idiom": "mac", "size": f"{pt}x{pt}", "scale": f"{scale}x", "filename": name})
with open(os.path.join(out_dir, "Contents.json"), "w") as fh:
    json.dump({"images": entries, "info": {"author": "xcode", "version": 1}}, fh, indent=2)
master.save(sys.argv[2])
