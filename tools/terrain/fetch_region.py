"""Bake a REAL region's elevation into a game terrain asset.

Source: AWS Open Data "Terrain Tiles" (Mapzen terrarium PNGs, SRTM-derived,
no auth): https://registry.opendata.aws/terrain-tiles/ — elevation per pixel
= (R*256 + G + B/256) - 32768 meters. At zoom 12 and ~49°N a pixel spans
~25 m — exactly one game tile — so a 256x256 crop is a true 6.4 x 6.4 km
region at native resolution.

Output: game/data/terrain/<name>.json
  {"name", "source", "center": [lat, lon], "levels": [256*256 ints row-major]}
levels = (elevation - min) / 5 m, clamped to `--max-levels` (Terrain's
physics step is 5 m/level). The game's Terrain samples this instead of the
noise field when a scenario picks the region (noise stays the default —
smokes and old saves are untouched).

Usage:
  .venv/bin/python tools/terrain/fetch_region.py kraichgau 49.08 8.73
  .venv/bin/python tools/terrain/fetch_region.py schwarzwald 48.75 8.55
(needs Pillow + requests in the invoking venv)
"""
from __future__ import annotations

import io
import json
import math
import sys
from pathlib import Path

import requests
from PIL import Image

OUT_DIR = Path(__file__).resolve().parents[2] / "game" / "data" / "terrain"
ZOOM = 12
SIZE = 256          # game map tiles per side
LEVEL_M = 5.0       # Terrain physics step
URL = "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png"


def _tile_of(lat: float, lon: float) -> tuple[float, float]:
    n = 2.0 ** ZOOM
    x = (lon + 180.0) / 360.0 * n
    lat_r = math.radians(lat)
    y = (1.0 - math.asinh(math.tan(lat_r)) / math.pi) / 2.0 * n
    return x, y


def fetch(name: str, lat: float, lon: float, max_levels: int = 40) -> None:
    cx, cy = _tile_of(lat, lon)
    px, py = int(cx * 256), int(cy * 256)     # global pixel of the center
    x0, y0 = px - SIZE // 2, py - SIZE // 2   # top-left global pixel
    tiles = {(gx // 256, gy // 256)
             for gx in (x0, x0 + SIZE - 1) for gy in (y0, y0 + SIZE - 1)}
    mosaic = Image.new("RGB", (512, 512))
    tx0, ty0 = min(t[0] for t in tiles), min(t[1] for t in tiles)
    for tx in (tx0, tx0 + 1):
        for ty in (ty0, ty0 + 1):
            r = requests.get(URL.format(z=ZOOM, x=tx, y=ty), timeout=30)
            r.raise_for_status()
            mosaic.paste(Image.open(io.BytesIO(r.content)),
                         ((tx - tx0) * 256, (ty - ty0) * 256))
    crop = mosaic.crop((x0 - tx0 * 256, y0 - ty0 * 256,
                        x0 - tx0 * 256 + SIZE, y0 - ty0 * 256 + SIZE))
    elev = [[(p[0] * 256 + p[1] + p[2] / 256.0) - 32768.0
             for p in (crop.getpixel((x, y)) for x in range(SIZE))]
            for y in range(SIZE)]
    lo = min(min(row) for row in elev)
    hi = max(max(row) for row in elev)
    # native 5 m/level up to max_levels; steeper regions COMPRESS the whole
    # range proportionally instead of clamping (a clamp pancakes plateaus)
    n_levels = min(max_levels, max(1, int((hi - lo) / LEVEL_M)))
    levels = [min(n_levels, int((v - lo) / (hi - lo + 1e-9) * (n_levels + 1)))
              for row in elev for v in row]
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    out = OUT_DIR / f"{name}.json"
    out.write_text(json.dumps({
        "name": name,
        "source": "AWS Terrain Tiles (Mapzen terrarium, SRTM-derived), z%d" % ZOOM,
        "center": [lat, lon],
        "relief_m": round(hi - lo, 1),
        "m_per_level": round((hi - lo) / (n_levels + 1), 2),
        "size": SIZE,
        "levels": levels,
    }))
    n_levels = max(levels) + 1
    print(f"wrote {out}  relief {hi - lo:.0f} m -> {n_levels} levels "
          f"(clamped at {max_levels})")


if __name__ == "__main__":
    if len(sys.argv) < 4:
        sys.exit("usage: fetch_region.py <name> <lat> <lon> [max_levels]")
    fetch(sys.argv[1], float(sys.argv[2]), float(sys.argv[3]),
          int(sys.argv[4]) if len(sys.argv) > 4 else 40)
