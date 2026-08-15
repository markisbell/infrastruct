"""Street geometry lab: rasterise OSM ways to game tiles, SCORE the shape,
and draw the result as text — no engine, no GPU, milliseconds per run.

The point: "does it look like a street" is a SHAPE property, and shape was
the one thing the game-side checks never measured. Connectivity said the
network was perfect while it rendered as a sawtooth.

pipeline stages are switchable so variants can be compared head to head.
"""
from __future__ import annotations

import json
import math
from collections import Counter

S = 256
ORTH = ((1, 0), (-1, 0), (0, 1), (0, -1))
OSM = json.load(open("game/data/terrain/heidelberg_osm.json"))


# ── pipeline stages ───────────────────────────────────────────────────

def simplify(pts, tol):
    """Douglas-Peucker. Micro-wiggles below a tile become bends we cannot
    render, so drop them before they reach the grid."""
    if len(pts) < 3 or tol <= 0:
        return pts
    a, b = pts[0], pts[-1]
    dx, dy = b[0] - a[0], b[1] - a[1]
    span = math.hypot(dx, dy)
    worst, idx = -1.0, 0
    for i in range(1, len(pts) - 1):
        p = pts[i]
        if span == 0:
            d = math.hypot(p[0] - a[0], p[1] - a[1])
        else:
            d = abs(dy * p[0] - dx * p[1] + b[0] * a[1] - b[1] * a[0]) / span
        if d > worst:
            worst, idx = d, i
    if worst <= tol:
        return [a, b]
    return simplify(pts[:idx + 1], tol) + simplify(pts[idx:], tol)[1:]


def snap_axis(pts, deg):
    """A street a few degrees off true will staircase across the whole map.
    Within `deg` of an axis, flatten it onto that axis: one long straight
    run reads as a street, a 1-tile staircase reads as noise."""
    if deg <= 0:
        return pts
    out = [list(pts[0])]
    for i in range(1, len(pts)):
        x0, y0 = out[-1]
        x1, y1 = pts[i]
        ang = math.degrees(math.atan2(y1 - y0, x1 - x0))
        if min(abs(ang), abs(abs(ang) - 180)) <= deg:
            y1 = y0                      # near-horizontal -> horizontal
        elif abs(abs(ang) - 90) <= deg:
            x1 = x0                      # near-vertical -> vertical
        out.append([x1, y1])
    # re-anchor on the true endpoint, exactly as Scenarios.snap_way does:
    # snapping chains, so the way drifts off the nodes it SHARES with the
    # streets it meets. Without this the network shatters (17 -> 85 pieces)
    # while every shape metric improves.
    if tuple(out[-1]) != tuple(pts[-1]):
        out.append(list(pts[-1]))
    return [tuple(p) for p in out]


def paved_line(a, b):
    """The game's Scenarios.paved_line: 4-connected, elbow inserted."""
    out, prev = [a], a
    steps = max(abs(b[0] - a[0]), abs(b[1] - a[1]))
    for s in range(1, steps + 1):
        cur = (round(a[0] + (b[0] - a[0]) * s / steps),
               round(a[1] + (b[1] - a[1]) * s / steps))
        if cur == prev:
            continue
        if cur[0] != prev[0] and cur[1] != prev[1]:
            out.append((cur[0], prev[1]))
        out.append(cur)
        prev = cur
    return out


def thin(tiles):
    """Remove tiles that only fatten the road: a 2x2 solid block is asphalt,
    not a street. Drop one only when the rest stays connected locally."""
    tiles = set(tiles)
    for t in sorted(tiles):
        x, y = t
        square = [(x, y), (x + 1, y), (x, y + 1), (x + 1, y + 1)]
        if all(q in tiles for q in square):
            nbrs = [q for q in ORTH if (x + q[0], y + q[1]) in tiles]
            if len(nbrs) <= 2:
                tiles.discard(t)
    return tiles


def build(tol=0.0, deg=0.0, do_thin=False, minor=True):
    strip = None
    if minor:
        b = [tuple(p) for p in OSM["buildings"]]
        strip = (min(p[0] for p in b) - 2, max(p[0] for p in b) + 2,
                 min(p[1] for p in b) - 2, max(p[1] for p in b) + 2)
    tiles = set()
    for bucket in ("main", "minor"):
        if bucket == "minor" and not minor:
            continue
        for w in OSM["streets"][bucket]:
            pts = snap_axis(simplify([tuple(q) for q in w["pts"]], tol), deg)
            for i in range(len(pts) - 1):
                for q in paved_line(pts[i], pts[i + 1]):
                    if not (0 <= q[0] < S and 0 <= q[1] < S):
                        continue
                    if bucket == "minor" and strip and not (
                            strip[0] <= q[0] <= strip[1]
                            and strip[2] <= q[1] <= strip[3]):
                        continue
                    tiles.add(q)
    return thin(tiles) if do_thin else tiles


# ── scoring ───────────────────────────────────────────────────────────

def score(tiles):
    straight = bend = 0
    mask = Counter()
    for t in tiles:
        ns = [q for q in ORTH if (t[0] + q[0], t[1] + q[1]) in tiles]
        mask[len(ns)] += 1
        if len(ns) == 2:
            if ns[0][0] == -ns[1][0] and ns[0][1] == -ns[1][1]:
                straight += 1
            else:
                bend += 1
    blobs = sum(1 for t in tiles if all(
        (t[0] + dx, t[1] + dy) in tiles
        for dx, dy in ((0, 0), (1, 0), (0, 1), (1, 1))))
    # mean uninterrupted straight run, the number that decides "street or noise"
    runs = []
    for axis in (0, 1):
        seen = set()
        for t in sorted(tiles):
            if t in seen:
                continue
            step = (1, 0) if axis == 0 else (0, 1)
            back = (t[0] - step[0], t[1] - step[1])
            if back in tiles:
                continue
            n, cur = 0, t
            while cur in tiles:
                seen.add(cur)
                n += 1
                cur = (cur[0] + step[0], cur[1] + step[1])
            if n > 1:
                runs.append(n)
    # CONNECTIVITY belongs in the same score as shape. Measuring shape
    # alone once produced a "better" variant that had quietly torn the
    # network from 17 components into 85: snapping drifts a way off the
    # endpoints it SHARES with its neighbours. Optimising the metric you
    # happen to be watching is the whole trap.
    seen, components, largest = set(), 0, 0
    for t in tiles:
        if t in seen:
            continue
        components += 1
        stack, n = [t], 0
        seen.add(t)
        while stack:
            cur = stack.pop()
            n += 1
            for dx, dy in ORTH:
                q = (cur[0] + dx, cur[1] + dy)
                if q in tiles and q not in seen:
                    seen.add(q)
                    stack.append(q)
        largest = max(largest, n)
    return {"tiles": len(tiles), "bend_pct": round(100 * bend / max(1, bend + straight)),
            "blobs": blobs, "junctions": mask[3] + mask[4],
            "mean_run": round(sum(runs) / max(1, len(runs)), 1),
            "components": components, "largest": largest}


def draw(tiles, x0, y0, w=76, h=34):
    print("    " + "".join(str((x0 + i) // 10 % 10) for i in range(w)))
    for y in range(y0, y0 + h):
        row = "".join("#" if (x, y) in tiles else "." for x in range(x0, x0 + w))
        print(f"{y:3} {row}")


if __name__ == "__main__":
    variants = [
        ("as shipped        ", dict()),
        ("simplify 1.0      ", dict(tol=1.0)),
        ("simplify+snap 12  ", dict(tol=1.0, deg=12)),
        ("simplify+snap 20  ", dict(tol=1.5, deg=20)),
        ("+thin             ", dict(tol=1.5, deg=20, do_thin=True)),
        # what Scenarios actually ships (STREET_SIMPLIFY_TOL / _SNAP_DEG):
        # full axis snap is the only setting that really moves bend%, and
        # bend% is what decides "street or sawtooth" on an orthogonal grid
        ("SHIPPED: snap 45  ", dict(tol=1.5, deg=45, do_thin=True)),
        ("main roads only   ", dict(tol=1.5, deg=45, do_thin=True, minor=False)),
    ]
    print(f"{'variant':20}{'tiles':>7}{'bend%':>7}{'blobs':>7}{'junc':>6}"
          f"{'mean run':>10}{'comps':>7}{'largest':>9}")
    for name, kw in variants:
        s = score(build(**kw))
        print(f"{name:20}{s['tiles']:7}{s['bend_pct']:7}{s['blobs']:7}"
              f"{s['junctions']:6}{s['mean_run']:10}{s['components']:7}"
              f"{s['largest']:9}")
