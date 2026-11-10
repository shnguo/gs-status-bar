"""Build the macOS app icon set from Resources/AppIconArt.png.

The art is full-bleed square artwork. This script masks it into the rounded
tile (same geometry as Resources/AppIcon.svg) and writes every size the
asset catalog needs. Run: python3 scripts/make-app-icon.py (needs Pillow).
"""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
ART = ROOT / "Resources/AppIconArt.png"
OUT = ROOT / "Resources/AppStoreAssets.xcassets/AppIcon.appiconset"
SS = 4                      # supersample for smooth edges
X, SIZE, R = 92, 840, 205   # tile offset, size and corner radius on a 1024 canvas

art = Image.open(ART).convert("RGBA").resize((SIZE * SS, SIZE * SS), Image.LANCZOS)
mask = Image.new("L", art.size, 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, SIZE * SS - 1, SIZE * SS - 1], R * SS, fill=255)
tile = Image.new("RGBA", art.size, (0, 0, 0, 0))
tile.paste(art, (0, 0), mask)

# Faint warm hairline so the light tile keeps a crisp edge.
rim = Image.new("RGBA", art.size, (0, 0, 0, 0))
ImageDraw.Draw(rim).rounded_rectangle(
    [0, 0, SIZE * SS - 1, SIZE * SS - 1], R * SS,
    outline=(90, 70, 50, 34), width=2 * SS)
tile = Image.alpha_composite(tile, rim)
tile = tile.resize((SIZE, SIZE), Image.LANCZOS)

# Soft drop shadow under the tile, so it stands out on light backgrounds.
shadow_mask = Image.new("L", (1024, 1024), 0)
ImageDraw.Draw(shadow_mask).rounded_rectangle(
    [X, X + 10, X + SIZE - 1, X + SIZE - 1 + 10], R, fill=int(255 * 0.30))
shadow = Image.new("RGBA", (1024, 1024), (40, 30, 20, 0))
shadow.putalpha(shadow_mask.filter(ImageFilter.GaussianBlur(14)))

master = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
master = Image.alpha_composite(master, shadow)
layer = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
layer.paste(tile, (X, X))
master = Image.alpha_composite(master, layer)

for size in (16, 32, 64, 128, 256, 512, 1024):
    master.resize((size, size), Image.LANCZOS).save(OUT / f"AppIcon-{size}.png")
print(f"Wrote icons to {OUT}")
