"""Build tools/profiles/lpg_dhw_library.json from raw LPG warm-water runs.

The committed library is the game's DHW analog of rtpowerflow's cached
``lpg_library/`` (electricity): behaviorally CONSISTENT households — the
same 8 CHR archetypes, simulated by the same LoadProfileGenerator.

Regeneration recipe (the raw runs are NOT committed, ~100 MB of 1-min
arrays): in a scratch venv, ``pip install pyloadprofilegenerator`` (pulls
the official LPG 10.10.0 Linux binaries on first use), then per archetype

    lpg_execution.execute_lpg_single_household(
        2023, Households.<CHRxx_...>, HouseTypes.HT23_No_Infrastructure_at_all,
        startdate="2023-01-01", enddate="2023-12-31", random_seed=7)

and store each result's 1-min "Warm Water" column into one npz
(keys ``<CHRxx>_warm``). This script collapses that npz into per-archetype
per-day-kind mean 96-tick shapes:

  - day kinds from the real 2023 calendar (Jan 1 was a Sunday); German
    national holidays behave like Sundays in LPG and are EXCLUDED from the
    workday mean rather than diluting it
  - 1-min -> 15-min means, then the day-kind mean per archetype
  - shapes stay in raw liters/tick units; normalization to factors happens
    in gen_profiles.py (dhw subcommand) where the mix is composed

Usage: python tools/profiles/gen_lpg_dhw.py <raw.npz>
"""
from __future__ import annotations

import datetime
import json
import sys
from pathlib import Path

import numpy as np

LIB = Path(__file__).resolve().parent / "lpg_dhw_library.json"
YEAR = 2023
#: German national holidays 2023 (LPG simulates them as home days)
HOLIDAYS = {(1, 1), (4, 7), (4, 10), (5, 1), (5, 18), (5, 29),
            (10, 3), (12, 25), (12, 26)}


def day_kind(date: datetime.date) -> str:
    if (date.month, date.day) in HOLIDAYS:
        return "holiday"
    return {5: "saturday", 6: "sunday"}.get(date.weekday(), "workday")


def main(npz_path: str) -> None:
    raw = np.load(npz_path)
    lib: dict = {
        "source": "LoadProfileGenerator 10.10.0 via pylpg, load type 'Warm Water'",
        "year": YEAR, "seed": 7, "housetype": "HT23 No Infrastructure at all",
        "resolution_minutes": 15, "steps": 96,
        "holidays_excluded": sorted("%02d-%02d" % md for md in HOLIDAYS),
        "archetypes": {},
    }
    for key in sorted(raw.files):
        if not key.endswith("_warm"):
            continue
        cid = key[:-5]
        minutes = raw[key]
        days = minutes[: 365 * 1440].reshape(365, 1440)
        ticks = days.reshape(365, 96, 15).mean(axis=2)  # liters/min avg per tick
        buckets: dict[str, list[np.ndarray]] = {}
        for doy in range(365):
            date = datetime.date(YEAR, 1, 1) + datetime.timedelta(days=doy)
            buckets.setdefault(day_kind(date), []).append(ticks[doy])
        entry = {"annual_litres": round(float(minutes.sum()), 1)}
        for kind in ("workday", "saturday", "sunday"):
            entry[kind] = [round(float(x), 5)
                           for x in np.mean(buckets[kind], axis=0)]
            entry["n_days_" + kind] = len(buckets[kind])
        lib["archetypes"][cid] = entry
    LIB.write_text(json.dumps(lib, indent=1), encoding="utf-8")
    print(f"wrote {LIB} ({len(lib['archetypes'])} archetypes)")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: gen_lpg_dhw.py <raw_runs.npz>")
    main(sys.argv[1])
