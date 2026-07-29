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


def gen_pv() -> None:
    """Real measured PV day shapes from rtpowerflow's rooftop plant
    (data/real_pv_days.json, 1-min raster) downsampled to the game's 96
    quarter-hour ticks. Shapes are fractions of kWp; the game picks a day
    deterministically per game-day and scales by season (the measurement
    campaign covers late spring/summer only)."""
    src = ROOT / "backends" / "rtpowerflow" / "data" / "real_pv_days.json"
    data = json.loads(src.read_text(encoding="utf-8"))
    days = []
    for day in data["days"]:
        shape = day["shape"]
        ticks = [
            round(sum(shape[i * 15:(i + 1) * 15]) / 15.0, 4) for i in range(96)]
        days.append(ticks)
    pack = _load_pack()
    pack["pv_days"] = days
    pack["meta"]["pv_source"] = "%s (%d measured days, fractions of kWp)" % (
        data.get("source", "rtpowerflow real_pv_days"), len(days))
    _save_pack(pack)


def gen_ev() -> None:
    """Diversified home-charging shape (mirrors rtpowerflow's synthetic
    additive EV model): arrivals spread 16:30-21:00 on workdays (later and
    flatter on weekends), ~2.2 h at full charger power per arrival. The
    shape is the EXPECTED per-EV load as a fraction of charger power."""
    import math

    def day_shape(arrival_mean_h: float, arrival_std_h: float,
                  charge_h: float) -> list[float]:
        out = [0.0] * 96
        for k in range(96):
            t_h = k / 4.0
            density = 0.0
            for offset in (-24.0, 0.0, 24.0):  # wrap past midnight
                x = t_h + offset
                # probability an EV that arrived at g is still charging at x:
                # integral of the gaussian arrival density over the window
                lo = (x - charge_h - arrival_mean_h) / (arrival_std_h * math.sqrt(2))
                hi = (x - arrival_mean_h) / (arrival_std_h * math.sqrt(2))
                density += 0.5 * (math.erf(hi) - math.erf(lo))
            out[k] = round(density, 4)
        return out

    pack = _load_pack()
    pack["ev"] = {
        "workday": day_shape(18.0, 1.6, 2.2),
        "saturday": day_shape(15.5, 3.0, 2.2),
        "sunday": day_shape(16.5, 3.2, 2.2),
    }
    pack["meta"]["ev_source"] = (
        "synthetic diversified home charging (gaussian arrivals x 2.2 h), "
        "expected per-EV fraction of charger power")
    _save_pack(pack)


if __name__ == "__main__":
    commands = {"elec": gen_elec, "water": gen_water, "pv": gen_pv, "ev": gen_ev}
    if len(sys.argv) != 2 or sys.argv[1] not in commands:
        sys.exit("usage: gen_profiles.py elec|water|pv|ev")
    commands[sys.argv[1]]()
