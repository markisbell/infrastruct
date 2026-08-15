"""Bake a real city's STREETS and BUILDING FOOTPRINTS into a game asset.

Source: OpenStreetMap via the Overpass API. Projected with the SAME Web
Mercator math as fetch_region.py, so the geometry lands exactly on the
matching baked DEM (<name>.json) tile for tile.

Output: game/data/terrain/<name>_osm.json
  {"streets": {"main": [{"name", "pts"}], "minor": [...]}, "buildings": [[x, y]]}

LICENCE: OSM data is ODbL — attribution and share-alike ride with the
generated file. The DEM from fetch_region.py (AWS/SRTM) is not.

Usage: .venv/bin/python tools/terrain/fetch_osm.py   (needs requests)
"""
import json
import math
import sys
import time
from pathlib import Path

import requests

ZOOM, SIZE = 12, 256
CENTER_LAT, CENTER_LON = 49.4100, 8.7000
# the whole map window
S, W, N, E = 49.3810, 8.6560, 49.4390, 8.7440
# "close to the river": the Altstadt + Neuenheim strip, where we take real
# building footprints rather than grown houses
AS, AW, AN, AE = 49.4085, 8.6900, 49.4200, 8.7260

URL = "https://overpass-api.de/api/interpreter"
OUT = Path("game/data/terrain/heidelberg_osm.json")

MAIN = ("motorway", "trunk", "primary", "secondary", "tertiary")
MINOR = ("residential", "unclassified", "living_street")


def tile_of(lat, lon):
    n = 2.0**ZOOM
    x = (lon + 180.0) / 360.0 * n
    y = (1.0 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2.0 * n
    return x, y


cx, cy = tile_of(CENTER_LAT, CENTER_LON)
X0, Y0 = int(cx * 256) - SIZE // 2, int(cy * 256) - SIZE // 2


def to_grid(lat, lon):
    tx, ty = tile_of(lat, lon)
    return int(tx * 256) - X0, int(ty * 256) - Y0


ENDPOINTS = ("https://overpass-api.de/api/interpreter",
             "https://overpass.kumi.systems/api/interpreter",
             "https://overpass.osm.ch/api/interpreter")
HEADERS = {"User-Agent": "infrastruct-game/0.8 (city reference build; "
                         "contact: local dev)"}


def overpass(query: str) -> dict:
    for attempt in range(3):
        for url in ENDPOINTS:
            try:
                r = requests.post(url, data={"data": query},
                                  headers=HEADERS, timeout=180)
            except requests.RequestException as exc:
                print(f"  {url}: {exc}", file=sys.stderr)
                continue
            if r.status_code == 200:
                return r.json()
            print(f"  {url}: HTTP {r.status_code}", file=sys.stderr)
        time.sleep(6)
    raise SystemExit("overpass failed")


print("fetching streets…")
roads = overpass(f"""[out:json][timeout:180];
(way["highway"~"^({'|'.join(MAIN + MINOR)})$"]({S},{W},{N},{E}););
out geom;""")
print("fetching Altstadt building footprints…")
builds = overpass(f"""[out:json][timeout:180];
(way["building"]({AS},{AW},{AN},{AE}););
out geom;""")


def clip(p):
    x, y = p
    return 0 <= x < SIZE and 0 <= y < SIZE


streets = {"main": [], "minor": []}
for el in roads.get("elements", []):
    geom = el.get("geometry") or []
    if len(geom) < 2:
        continue
    pts, last = [], None
    for nd in geom:
        p = to_grid(nd["lat"], nd["lon"])
        if p != last:
            pts.append(list(p))
            last = p
    if len(pts) < 2:
        continue
    bucket = "main" if el["tags"].get("highway") in MAIN else "minor"
    streets[bucket].append({"name": el["tags"].get("name", ""), "pts": pts})

# building footprints -> the tiles their centroid falls on (one house per
# building; the game's tile is 25 m so a footprint is ~1 tile anyway)
seen = set()
buildings = []
for el in builds.get("elements", []):
    geom = el.get("geometry") or []
    if not geom:
        continue
    lat = sum(n["lat"] for n in geom) / len(geom)
    lon = sum(n["lon"] for n in geom) / len(geom)
    p = to_grid(lat, lon)
    if clip(p) and tuple(p) not in seen:
        seen.add(tuple(p))
        buildings.append(list(p))

named = sorted({s["name"] for s in streets["main"] if s["name"]})
print(f"\nstreets: {len(streets['main'])} main ways, "
      f"{len(streets['minor'])} minor ways")
print(f"named main streets ({len(named)}): {', '.join(named[:18])}…")
print(f"building tiles in the river strip: {len(buildings)}")

OUT.write_text(json.dumps({
    "source": "OpenStreetMap via Overpass API, (c) OpenStreetMap "
              "contributors, ODbL",
    "center": [CENTER_LAT, CENTER_LON],
    "zoom": ZOOM, "size": SIZE,
    "streets": streets,
    "buildings": buildings,
}))
print(f"wrote {OUT} ({OUT.stat().st_size // 1024} KB)")
