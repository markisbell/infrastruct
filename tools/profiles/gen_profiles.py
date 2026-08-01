"""Generate the game's bundled demand-profile pack (ROADMAP Phase 6 task 1).

Two subcommands because the sources live in different venvs — each merges
its section into game/data/profiles/residential_pack.json:

  .venv/bin/python       tools/profiles/gen_profiles.py elec
  .venv-water/bin/python tools/profiles/gen_profiles.py water

elec  — rtpowerflow's cached LPG household library (data/lpg_library/,
        LoadProfileGenerator 1-min day profiles: 8 archetypes x 18 sampled
        days across the year), equal-weight household mix downsampled to
        96 quarter-hour ticks and collapsed to 9 characteristic day shapes
        (winter/summer/transition x workday/saturday/sunday), normalized
        so the composed yearly mean is 1.0. Weekday classification is
        data-derived: doy%7==5/6 separate as Sat/Sun at >10 sigma on the
        midday-presence of the at-work archetypes (the library does not
        record its simulation year). Formerly demandlib BDEW H0.
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


def _doy_season(doy: int) -> str:
    """BDEW season windows on a day-of-year (non-leap calendar)."""
    import datetime
    d = datetime.date(2023, 1, 1) + datetime.timedelta(days=doy - 1)
    return _bdew_season(d.month, d.day)


def gen_elec() -> None:
    import numpy as np

    lib = ROOT / "backends" / "rtpowerflow" / "data" / "lpg_library"
    index = json.loads((lib / "index.json").read_text(encoding="utf-8"))

    # equal-weight household mix: average the ABSOLUTE kW curves so real
    # between-day levels (winter > summer evenings) survive into the cells
    cells: dict[str, list[np.ndarray]] = {}
    for arch in index["archetypes"]:
        doc = json.loads((lib / arch["file"]).read_text(encoding="utf-8"))
        for doy, curve in zip(doc["variant_day_of_year"], doc["variants_kw"]):
            kind = ("saturday" if doy % 7 == 5 else
                    "sunday" if doy % 7 == 6 else "workday")
            ticks = np.asarray(curve, dtype=float).reshape(96, 15).mean(axis=1)
            cells.setdefault(f"{_doy_season(doy)}_{kind}", []).append(ticks)

    mean_curves = {key: np.mean(curves, axis=0) for key, curves in cells.items()}
    # the 18-day grid samples no winter weekend and no transition saturday:
    # fall back to the kind's cross-season mean curve, level-scaled by the
    # season's workday level (weekend/workday level ratio assumed stable)
    kind_year = {
        kind: np.mean([c for key, curves in cells.items() if key.endswith(kind)
                       for c in curves], axis=0)
        for kind in DAY_KINDS}
    filled = []
    for season in GAME_SEASONS:
        for kind in DAY_KINDS:
            key = f"{season}_{kind}"
            if key not in mean_curves:
                level = (mean_curves[f"{season}_workday"].mean()
                         / kind_year["workday"].mean())
                mean_curves[key] = kind_year[kind] * level
                filled.append(key)

    # diversity smear: the library carries 8 fixed schedule templates, so
    # their synchronized dinners stack into a ~3.5x evening spike; a zone
    # aggregates ~150 INDEPENDENT households whose schedules scatter.
    # Circular gaussian over the day (sigma 30 min) models that offset —
    # the game's zone expectation is a neighborhood mean, not one template.
    ticks96 = np.arange(96)
    lag = np.minimum(ticks96, 96 - ticks96)
    kernel = np.exp(-0.5 * (lag / 2.0) ** 2)  # sigma = 2 ticks = 30 min
    kernel /= kernel.sum()
    for key, curve in mean_curves.items():
        mean_curves[key] = np.real(np.fft.ifft(
            np.fft.fft(curve) * np.fft.fft(kernel)))

    # composed yearly mean -> 1.0 under the game calendar (season lengths
    # 90/180/90 of 360, day kinds 5/1/1 of 7)
    season_w = {"winter": 0.25, "summer": 0.25, "transition": 0.5}
    kind_w = {"workday": 5 / 7, "saturday": 1 / 7, "sunday": 1 / 7}
    year_mean = sum(season_w[s] * kind_w[k] * mean_curves[f"{s}_{k}"].mean()
                    for s in GAME_SEASONS for k in DAY_KINDS)
    shapes = {key: [round(float(x), 4) for x in curve / year_mean]
              for key, curve in mean_curves.items()}

    pack = _load_pack()
    pack["elec"] = shapes
    pack["meta"]["elec_source"] = (
        "rtpowerflow lpg_library (%s, %d archetypes, equal-weight mix; "
        "Sat/Sun = doy%%7 5/6, data-derived; filled cells: %s)" % (
            index.get("source", "LPG"), len(index["archetypes"]),
            ", ".join(filled) or "none"))
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
    flatter on weekends), ~1.1 h at full 22-kW charger power per arrival
    (same ~24 kWh session the old 11-kW/2.2-h shape carried). The shape is
    the EXPECTED per-EV load as a fraction of charger power."""
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
        "workday": day_shape(18.0, 1.6, 1.1),
        "saturday": day_shape(15.5, 3.0, 1.1),
        "sunday": day_shape(16.5, 3.2, 1.1),
    }
    pack["meta"]["ev_source"] = (
        "synthetic diversified home charging (gaussian arrivals x 1.1 h "
        "at 22 kW, ~24 kWh/session), expected per-EV fraction of charger power")
    _save_pack(pack)


if __name__ == "__main__":
    commands = {"elec": gen_elec, "water": gen_water, "pv": gen_pv, "ev": gen_ev}
    if len(sys.argv) != 2 or sys.argv[1] not in commands:
        sys.exit("usage: gen_profiles.py elec|water|pv|ev")
    commands[sys.argv[1]]()
