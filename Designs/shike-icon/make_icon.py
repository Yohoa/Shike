import sys
from PIL import Image, ImageDraw, ImageFilter, ImageOps, ImageFont, ImageChops
D = sys.argv[1]
src = Image.open(f'{D}/hamster.jpg').convert('L')
k = 2282 / 2000
outline = [(1330,82),(1250,95),(1185,118),(1160,170),(1168,235),(1150,330),(1138,450),(1140,600),(1165,740),(1195,880),
           (1195,1000),(1215,1070),(1300,1085),(1420,1095),(1560,1080),(1700,1050),(1770,980),(1765,860),(1755,700),
           (1730,540),(1680,420),(1590,350),(1530,260),(1540,165),(1505,105),(1420,80)]
outline = [(x * k, y * k) for x, y in outline]
mask = Image.new('L', src.size, 0)
ImageDraw.Draw(mask).polygon(outline, fill=255)
mask = mask.filter(ImageFilter.GaussianBlur(14))
# Engraving: paper tone to white, lines to near-black ink.
ink = src.point(lambda v: max(0, min(255, int((v - 20) * 255 / (215 - 20)))))
white = Image.new('L', src.size, 255)
animal = Image.composite(ink, white, mask)
box = (int(1085 * k), int(55 * k), int(1820 * k), int(1120 * k))
animal = animal.crop(box)

S = 1024
icon = Image.new('RGBA', (S, S), (0, 0, 0, 0))
inset, size = 100, int(sys.argv[2]) if len(sys.argv) > 2 else 824
def squircle(n=5.0, scale=4):
    m = Image.new('L', (size * scale, size * scale), 0)
    r = size * scale / 2
    pts = []
    import math
    for i in range(720):
        t = 2 * math.pi * i / 720
        c, s = math.cos(t), math.sin(t)
        pts.append((r + r * (abs(c) ** (2 / n)) * (1 if c >= 0 else -1), r + r * (abs(s) ** (2 / n)) * (1 if s >= 0 else -1)))
    ImageDraw.Draw(m).polygon(pts, fill=255)
    return m.resize((size, size), Image.LANCZOS)
shape = squircle()

face = Image.new('RGB', (size, size), (251, 250, 246))
draw = ImageDraw.Draw(face)
u = size / 824
h = int(size * 0.80)
aw = int(animal.width * h / animal.height)
art = animal.resize((aw, h), Image.LANCZOS)
face.paste(ImageOps.colorize(art, (24, 22, 20), (251, 250, 246)), ((size - aw) // 2, (size - h) // 2 + int(10 * u)))

if size == 1024:
    face.save(f'{D}/layer-1024.png')
    raise SystemExit
shadow = Image.new('RGBA', (S, S), (0, 0, 0, 0))
sh = Image.new('L', (S, S), 0); sh.paste(shape, (inset, inset + 10))
shadow.putalpha(sh.point(lambda v: v * 0.35).filter(ImageFilter.GaussianBlur(14)))
icon.alpha_composite(shadow)
layer = Image.new('RGBA', (size, size)); layer.paste(face); layer.putalpha(shape)
icon.alpha_composite(layer, (inset, inset))
icon.save(f'{D}/icon-1024.png')
print('ok', aw, h)
