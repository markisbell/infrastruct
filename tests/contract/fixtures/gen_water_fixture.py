"""Generate water_fixture.json — the rtwaterflow contract-v1 test fixture.

Deterministic, dependency-free (stdlib only). A small hillside net built to
the game-side WaterTopology builder convention (the shape the gamebridge is
pinned against):

* ``native`` — the rtwaterflow five-file bundle (contract §3.1 water notes):
  tower junction ``twr`` whose ``elevation_m`` ALREADY includes the 25 m
  tower height (300 m base + 25 — the generator folds it in, the backend
  must NOT add it again), hub ``j0`` and three zone consumers at hillside
  elevations 300/302.5/305 m; pipes DN150 (``inner_diameter_mm`` 150,
  ``k_mm`` 0.1); consumers are 0.01 kg/s placeholders named like their zone
  (game-driven rows, contract §3.1); ``supply`` is MINIMAL — one ext_grid
  head entry at the tower node (p_bar 0.5, the tank-surface seed);
  ``environment`` is the 96-step horizon owner with a 10 °C placeholder
  series (per-step weather rules).
* ``zones`` — wz0–wz2 map onto the three consumers by NAME.
* ``devices`` — the HEAD source FIRST (slack-first convention): the
  ``water_tower`` (volume 200 m³ → shallow basin, soc = level fraction),
  then a ``well`` (source injection, q = yield_factor × rated) and a
  ``water_pump`` (source injection while enabled; couples out
  p_el_kw = ρ·g·Q·H/η ≥ 0).
* ``script`` — 96 steps × 900 s (one day): zone demands 0.5–2.5 m³/h with a
  morning peak (Gaussian around 07:30), ``temp_c`` ramping 10 → 25 °C,
  well ``yield_factor`` 1.0 and pump ``enabled`` true throughout — the
  3.6 m³/h injection roughly balances the mean demand, so the tower breathes
  inside its band (fills at night, dips through the peak).
* ``golden`` (final step, t=95: base demand ~0.6 m³/h per zone): all zones
  supplied ≥ 0.99 (Wagner PDD, healthy), zone p_bar within [1.5, 8.0] bar
  (DVGW band around ~2.3–2.8 bar at these elevations), tower soc within
  [0, 1] (lands ~0.9 after the net-positive day), pump coupling p_el_kw
  within [0.1, 1.0] (ρ·g·Q·H/η = 0.245 kW at 1.8 m³/h · 30 m · η 0.6).
* ``patch_probe`` — a second well at the hub ``j0`` (becomes a runtime
  source injection).

Regenerate:  python gen_water_fixture.py
"""
from __future__ import annotations

import json
import math
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT = HERE / "water_fixture.json"

STEPS = 96          # steps_per_day: 15-min contract ticks
DT_S = 900
BASE_ELEV_M = 300.0
TOWER_HEIGHT_M = 25.0  # folded into the tower junction's elevation_m HERE


def _geo(x: float, y: float) -> list[float]:
    """Game tile convention: geo = [48 + y·4e-4, 8 + x·4e-4]."""
    return [round(48.0 + y * 4e-4, 6), round(8.0 + x * 4e-4, 6)]


def _gauss_peak(t: int, base: float, amp: float, center: float,
                width: float) -> float:
    return round(base + amp * math.exp(-(((t - center) / width) ** 2)), 3)


def native_bundle() -> dict:
    junctions = [
        # the game adds tower_height_m into the head junction's elevation_m
        {"name": "twr", "kind": "source", "geo": _geo(0, 0),
         "elevation_m": BASE_ELEV_M + TOWER_HEIGHT_M, "pn_bar": 4.0},
        {"name": "j0", "kind": "node", "geo": _geo(0, 1),
         "elevation_m": BASE_ELEV_M, "pn_bar": 4.0},
        {"name": "wz0", "kind": "consumer", "geo": _geo(0, 2),
         "elevation_m": BASE_ELEV_M, "pn_bar": 4.0},
        {"name": "wz1", "kind": "consumer", "geo": _geo(1, 1),
         "elevation_m": BASE_ELEV_M + 2.5, "pn_bar": 4.0},
        {"name": "wz2", "kind": "consumer", "geo": _geo(2, 1),
         "elevation_m": BASE_ELEV_M + 5.0, "pn_bar": 4.0},
    ]
    pipes = [
        {"from_node": "twr", "to_node": "j0", "length_km": 0.3,
         "inner_diameter_mm": 150.0, "k_mm": 0.1},
        {"from_node": "j0", "to_node": "wz0", "length_km": 0.25,
         "inner_diameter_mm": 150.0, "k_mm": 0.1},
        {"from_node": "j0", "to_node": "wz1", "length_km": 0.25,
         "inner_diameter_mm": 150.0, "k_mm": 0.1},
        {"from_node": "wz1", "to_node": "wz2", "length_km": 0.25,
         "inner_diameter_mm": 150.0, "k_mm": 0.1},
    ]
    consumers = [
        # zone rows: placeholder base demand, name == zone id (game-driven)
        {"node": name, "name": name, "mdot_kg_per_s": 0.01,
         "kind": "residential"}
        for name in ("wz0", "wz1", "wz2")
    ]
    return {
        "network_structure": {"name": "contract_water_hillside",
                              "junctions": junctions},
        "pipes": {"pipes": pipes},
        "consumers": {"consumers": consumers},
        # MINIMAL supply: one ext_grid head at the tower node (p_bar 0.5 —
        # the tank surface seed; the water_tower device takes it over)
        "supply": {"supplies": [{"node": "twr", "name": "head",
                                 "kind": "ext_grid", "p_bar": 0.5}]},
        "environment": {"resolution_minutes": 1440 // STEPS, "steps": STEPS,
                        "t_air_c": [10.0] * STEPS},
    }


def fixture() -> dict:
    # zone demand series [m³/h]: base load + a morning peak, 0.5–2.5 m³/h
    demand = {
        "wz0": [_gauss_peak(t, 0.65, 1.85, 30.0, 10.0) for t in range(STEPS)],
        "wz1": [_gauss_peak(t, 0.55, 1.90, 32.0, 12.0) for t in range(STEPS)],
        "wz2": [_gauss_peak(t, 0.50, 1.90, 28.0, 9.0) for t in range(STEPS)],
    }
    temp_c = [round(10.0 + 15.0 * t / (STEPS - 1), 2) for t in range(STEPS)]

    return {
        "topology": {
            "contract": "1.1",
            "network_kind": "water",
            "name": "contract_water_fixture",
            "steps_per_day": STEPS,
            "native": native_bundle(),
            "zones": [
                {"id": "wz0", "consumer": "wz0"},
                {"id": "wz1", "consumer": "wz1"},
                {"id": "wz2", "consumer": "wz2"},
            ],
            "devices": [
                # HEAD source FIRST (slack-first convention): the tower
                {"id": "tower", "kind": "water_tower", "node": "twr",
                 "params": {"volume_m3": 200.0,
                            "tower_height_m": TOWER_HEIGHT_M}},
                {"id": "well", "kind": "well", "node": "j0",
                 "params": {"rated_m3_h": 1.8}},
                {"id": "pump", "kind": "water_pump", "node": "wz1",
                 "params": {"rated_m3_h": 1.8, "head_m": 30.0, "eta": 0.6}},
            ],
        },
        "script": {
            "steps": STEPS,
            "dt_s": DT_S,
            # generic fixture key; unit per network kind — water: m³/h (§4)
            "zone_demand_kw": demand,
            "device_setpoints": {
                "well": {"yield_factor": {"const": 1.0}},
                "pump": {"enabled": {"const": True}},
            },
            "weather": {"temp_c": temp_c},
        },
        "allowed_statuses": ["converged"],
        "golden": {
            "zones.wz0.supplied": [0.99, 1.0],
            "zones.wz1.supplied": [0.99, 1.0],
            "zones.wz2.supplied": [0.99, 1.0],
            "zones.wz0.detail.p_bar": [1.5, 8.0],
            "zones.wz1.detail.p_bar": [1.5, 8.0],
            "zones.wz2.detail.p_bar": [1.5, 8.0],
            "devices.tower.soc": [0.0, 1.0],
            # pump couples electricity OUT: POSITIVE = draws (§3.1)
            "coupling_out.pump.p_el_kw": [0.1, 1.0],
        },
        "patch_probe": {
            "id": "probe_well2", "kind": "well", "node": "j0",
            "params": {"rated_m3_h": 5.0},
        },
    }


def main() -> None:
    OUT.write_text(json.dumps(fixture(), indent=1, ensure_ascii=False) + "\n",
                   encoding="utf-8", newline="\n")
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
