"""Generate heat_fixture.json — the rtheatflow contract-v1 test fixture.

Deterministic, dependency-free (stdlib only). Authored as a minimal
3-consumer STAR network from scratch (the documented alternative to
resampling ``data/networks/appendix_a`` — appendix_a is already 96x15-min,
but a purpose-built star keeps the fixture self-contained and solves tier 1
across the whole scripted day):

* ``native`` — the rtheatflow five-file bundle (contract §3.1): plant node
  ``n0`` in the middle, three trenches to ``n1``/``n2``/``n3`` (ISOPLUS
  pre-insulated std types), one consumer per leaf (``hz0``–``hz2``,
  qext+treturn pair at 55 °C return). Consumer profile arrays are all-zero
  placeholders (game-driven rows per contract §3.1); the slack carries a
  85/70 heating curve so the scripted ``weather.temp_c`` visibly drives the
  supply temperature.
* ``zones`` — hz0–hz2 map onto the three consumers by NAME.
* ``devices`` — one device ``slack`` of kind ``chp`` (pq_ratio 0.5) bound to
  the bundle's slack producer: its realized heat feed couples out as
  ``p_el_kw = -0.5·q`` (NEGATIVE — production feeds the grid, contract §3.1).
* ``script`` — 96 steps x 900 s (one day): zone demands 20–80 kW(th) with a
  morning peak (Gaussian around 07:00–08:00), ``temp_c`` ramping −5 → 8 °C,
  CHP dispatch setpoint ``q_kw`` = 150 const (advisory on the slack — the
  plant balances the network; the realized feed is reported).
* ``golden`` (final step, t=95: ~62 kW demand + network losses at curve-min
  70 °C flow): all zones supplied 1.0, arriving supply temperature within
  [55, 95] °C, ``coupling_out.slack.p_el_kw`` within [−120, −20] (NEGATIVE).
* ``patch_probe`` — a boiler at existing node ``n1`` (becomes a
  heat_exchanger feed-in via the M4 CRUD).

Regenerate:  python gen_heat_fixture.py
"""
from __future__ import annotations

import json
import math
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT = HERE / "heat_fixture.json"

STEPS = 96          # steps_per_day: 15-min contract ticks
DT_S = 900
KELVIN = 273.15


def _gauss_peak(t: int, base: float, amp: float, center: float,
                width: float) -> float:
    return round(base + amp * math.exp(-(((t - center) / width) ** 2)), 3)


def native_bundle() -> dict:
    zeros = [0.0] * STEPS
    treturn = [round(55.0 + KELVIN, 2)] * STEPS

    network_structure = {
        "name": "contract_heat_star",
        "junctions": [
            {"name": "n0", "kind": "plant", "geo": [48.0, 7.8], "pn_bar": 6},
            {"name": "n1", "kind": "consumer", "geo": [48.003, 7.8], "pn_bar": 6},
            {"name": "n2", "kind": "consumer", "geo": [48.0, 7.8055], "pn_bar": 6},
            {"name": "n3", "kind": "consumer", "geo": [47.9975, 7.8], "pn_bar": 6},
        ],
    }
    pipes = {
        "pipes": [
            {"from_node": "n0", "to_node": "n1", "std_type": "ISOPLUS_DRE80_STD",
             "length_km": 0.4, "sections": 3,
             "geometry": [[48.0, 7.8], [48.003, 7.8]]},
            {"from_node": "n0", "to_node": "n2", "std_type": "ISOPLUS_DRE80_STD",
             "length_km": 0.35, "sections": 3,
             "geometry": [[48.0, 7.8], [48.0, 7.8055]]},
            {"from_node": "n0", "to_node": "n3", "std_type": "ISOPLUS_DRE80_STD",
             "length_km": 0.3, "sections": 3,
             "geometry": [[48.0, 7.8], [47.9975, 7.8]]},
        ]
    }
    consumers = {
        "resolution_minutes": 1440 // STEPS,
        "steps": STEPS,
        "consumers": [
            {"node": node, "name": name,
             "q_sh_w": list(zeros), "q_dhw_w": list(zeros),
             "treturn_k": list(treturn),
             "q_design_w": 80000.0, "t_supply_min_c": 55.0}
            for node, name in (("n1", "hz0"), ("n2", "hz1"), ("n3", "hz2"))
        ],
    }
    producers = {
        "producers": [
            {"node": "n0", "name": "heating plant", "kind": "slack",
             "p_flow_bar": 6.0, "plift_bar": 2.0, "t_flow_k": 358.15,
             "heating_curve": {"t_amb_design_c": -12.0,
                               "t_flow_design_c": 85.0,
                               "t_flow_min_c": 70.0,
                               "t_room_c": 20.0, "n": 1.0}}
        ]
    }
    weather = {
        "resolution_minutes": 1440 // STEPS,
        "steps": STEPS,
        # profile mirrors the scripted override ramp (the override wins)
        "t_amb_c": [round(-5.0 + 13.0 * t / (STEPS - 1), 2) for t in range(STEPS)],
        "t_ground_c": [8.0] * STEPS,
    }
    return {
        "network_structure": network_structure,
        "pipes": pipes,
        "consumers": consumers,
        "producers": producers,
        "weather": weather,
    }


def fixture() -> dict:
    # zone demand series [kW(th)]: base load + a morning peak, 20–80 kW
    demand = {
        "hz0": [_gauss_peak(t, 22.0, 58.0, 30.0, 10.0) for t in range(STEPS)],
        "hz1": [_gauss_peak(t, 20.0, 50.0, 32.0, 12.0) for t in range(STEPS)],
        "hz2": [_gauss_peak(t, 20.0, 40.0, 28.0, 9.0) for t in range(STEPS)],
    }
    temp_c = [round(-5.0 + 13.0 * t / (STEPS - 1), 2) for t in range(STEPS)]

    return {
        "topology": {
            "contract": "1.0",
            "network_kind": "heat",
            "name": "contract_heat_fixture",
            "steps_per_day": STEPS,
            "native": native_bundle(),
            "zones": [
                {"id": "hz0", "consumer": "hz0"},
                {"id": "hz1", "consumer": "hz1"},
                {"id": "hz2", "consumer": "hz2"},
            ],
            "devices": [
                {"id": "slack", "kind": "chp", "node": "n0",
                 "params": {"pq_ratio": 0.5}},
            ],
        },
        "script": {
            "steps": STEPS,
            "dt_s": DT_S,
            "zone_demand_kw": demand,
            "device_setpoints": {"slack": {"q_kw": {"const": 150.0}}},
            "weather": {"temp_c": temp_c},
        },
        "allowed_statuses": ["converged", "degraded"],
        "golden": {
            "zones.hz0.supplied": [1.0, 1.0],
            "zones.hz1.supplied": [1.0, 1.0],
            "zones.hz2.supplied": [1.0, 1.0],
            "zones.hz0.detail.t_supply_c": [55.0, 95.0],
            "zones.hz1.detail.t_supply_c": [55.0, 95.0],
            "zones.hz2.detail.t_supply_c": [55.0, 95.0],
            # CHP couples electricity OUT: negative = feeds the grid (§3.1)
            "coupling_out.slack.p_el_kw": [-120.0, -20.0],
        },
        "patch_probe": {
            "id": "probe_boiler", "kind": "boiler", "node": "n1",
            "params": {"eta": 0.9},
        },
    }


def main() -> None:
    OUT.write_text(json.dumps(fixture(), indent=1, ensure_ascii=False) + "\n",
                   encoding="utf-8", newline="\n")
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
