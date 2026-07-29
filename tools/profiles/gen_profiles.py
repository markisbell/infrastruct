"""Generate the game's bundled demand-profile pack (ROADMAP Phase 6 task 1).

Two subcommands because the sources live in different venvs — each merges
its section into game/data/profiles/residential_pack.json:

  .venv-heat/Scripts/python  tools/profiles/gen_profiles.py elec
  .venv-water/Scripts/python tools/profiles/gen_profiles.py water

elec  — demandlib BDEW H0 (dynamized) for a full year at 15 min, collapsed
        to 9 characteristic day shapes (winter/summer/transition x
        workday/saturday/sunday), 96 quarter-hour factors each, normalized
        so the composed yearly mean is 1.0.
water — rtwaterflow's own demand engine archetype ("residential", the
        DVGW W 410-normalized shapes): 24 h workday/saturday/sunday shapes
        resampled to 96 ticks + weekend volume factors + seasonal amplitude
        (peak mid-July). Deterministic expectation — no stochastic noise.

Space heating stays a live physics formula in the game (weather-driven);
domestic hot water keeps its VDI-style day shape — only electricity and
water come from this pack (heat acceptance scenarios are temperature-
calibrated and must not silently shift).
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PACK = ROOT / "game" / "data" / "profiles" / "residential_pack.json"

GAME_SEASONS = ("winter", "summer", "transition")
DAY_KINDS = ("workday", "saturday", "sunday")


def _load_pack() -> dict:
    if PACK.exists():
        return json.loads(PACK.read_text(encoding="utf-8"))
    return {"meta": {"format": 1, "archetype": "residential"}}


def _save_pack(pack: dict) -> None:
    PACK.parent.mkdir(parents=True, exist_ok=True)
    PACK.write_text(json.dumps(pack, indent=1), encoding="utf-8")
    print(f"wrote {PACK}")


def _bdew_season(month: int, day: int) -> str:
    """Official BDEW SLP season windows."""
    md = (month, day)
    if md >= (11, 1) or md <= (3, 20):
        return "winter"
    if (5, 15) <= md <= (9, 14):
        return "summer"
    return "transition"


def gen_elec() -> None:
    import pandas as pd
    from demandlib import bdew

    # dynamized H0 for a reference year; the absolute scale is irrelevant —
    # only the SHAPE survives the normalization below
    year = 2023
    slp = bdew.ElecSlp(year)
    series = slp.get_scaled_power_profiles({"h0": 1000.0})["h0"]
    frame = pd.DataFrame({"v": series})
    frame["season"] = [
        _bdew_season(ts.month, ts.day) for ts in frame.index]
    frame["kind"] = [
        "sunday" if ts.dayofweek == 6 else
        "saturday" if ts.dayofweek == 5 else "workday"
        for ts in frame.index]
    frame["quarter"] = frame.index.hour * 4 + frame.index.minute // 15

    mean = frame["v"].mean()
    shapes: dict[str, list[float]] = {}
    for season in GAME_SEASONS:
        for kind in DAY_KINDS:
            group = frame[(frame["season"] == season) & (frame["kind"] == kind)]
            shape = group.groupby("quarter")["v"].mean() / mean
            assert len(shape) == 96, f"{season}_{kind}: {len(shape)} quarters"
            shapes[f"{season}_{kind}"] = [round(float(x), 4) for x in shape]

    pack = _load_pack()
    pack["elec"] = shapes
    pack["meta"]["elec_source"] = f"demandlib BDEW H0 (dynamized), year {year}"
    _save_pack(pack)


def gen_water() -> None:
    import numpy as np
    from rtwaterflow.demand.archetypes import params_for

    p = params_for("residential")
    shapes = {}
    for kind, hourly in (("workday", p.workday), ("saturday", p.saturday),
                         ("sunday", p.sunday)):
        ticks = np.repeat(np.asarray(hourly, dtype=float), 4)  # staircase, 96
        shapes[kind] = [round(float(x), 4) for x in ticks / ticks.mean()]
    # weekly volume normalization so the composed mean is 1.0
    weekly = (5.0 + p.saturday_factor + p.sunday_factor) / 7.0
    pack = _load_pack()
    pack["water"] = {
        "shapes": shapes,
        "saturday_factor": round(p.saturday_factor / weekly, 4),
        "sunday_factor": round(p.sunday_factor / weekly, 4),
        "workday_factor": round(1.0 / weekly, 4),
        "season_amp": p.season_amp,     # ± around 1.0, peak mid-July
    }
    pack["meta"]["water_source"] = "rtwaterflow demand engine, archetype 'residential'"
    _save_pack(pack)


if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1] not in ("elec", "water"):
        sys.exit("usage: gen_profiles.py elec|water")
    gen_elec() if sys.argv[1] == "elec" else gen_water()
