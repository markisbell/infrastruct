"""Generate ``power_fixture.json`` — the shared contract-v1 fixture for
rtpowerflow (docs/contract/v1.md; fixture format: tests/contract/README.md).

Deterministic, stdlib-only. Rerun after changing any parameter:

    python gen_power_fixture.py            # writes power_fixture.json here

Network (contract §3.1, authored per the Phase-2 task; battery added with
the Phase-3 backend slice / contract 1.1; island added with contract 1.2):
    5 buses ``b0``-``b4``, one 0.4-kV chain of NAYY 4x150 SE segments
    (0.3 km hops), 10 zones spread 3/2/2/3 over ``b1``-``b4``, devices:
    slack@b0 (vm_pu 1.0) · generator gen1@b1 (p_max_kw 500, dispatched
    const 200 kW) · pv pv1@b3 (p_rated_kw 200, midday bell) · wind
    wind1@b4 (p_rated_kw 300, varied series) · coupling_load cpl_heat@b2
    (never fed by the suite — held at 0) · battery bat1@b2 (e_kwh 200,
    p_max_kw 100, charge-at-midday / discharge-in-the-evening dispatch,
    0 kW at the final step so the golden slack band is untouched; sized so
    neither the p_max nor the SoC bounds ever clamp — SoC runs 0.5 → ~0.95
    → ~0.16, inside the [0, 1] golden). 96 steps/day, dt_s 900.

    PLUS (contract 1.2) a DISCONNECTED island ``i0``-``i1``: grid_forming
    gfi@i0 (vm_pu 1.0, e_kwh 200, p_max_kw 100) as the island's slack,
    zone ``zi``@i1 drawing a constant 20 kW. 20 kW × 24 h = 480 kWh drains
    the 100-kWh half charge before midday — DELIBERATE: the backend must
    keep solving (report, never enforce), pin soc 0 + the storage_empty
    violation at the final step while ``zi`` stays supplied (frequency
    collapse is the game EMS's call, contract §3.1 grid-forming note).

Boundary script: one full day. Zone demands 10-40 kW with a morning/evening
double peak; the b1 zones keep a late-evening plateau so the constant
200-kW generator behind the first segment stays roughly absorbed at the
final step — the golden window checks that step (t=95, 23:45): every zone
v_pu in [0.93, 1.02], supplied == 1.0, slack import/export in a sane band.
Midday deliberately over-produces (pv + gen) — overvoltage/overload
VIOLATIONS are data the game reacts to, and every step still converges.
"""
from __future__ import annotations

import json
import math
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT = HERE / "power_fixture.json"

STEPS = 96
DT_S = 900

# zone id -> bus name (3/2/2/3 over b1..b4)
ZONE_BUS = {
    "z0": "b1", "z1": "b1", "z2": "b1",
    "z3": "b2", "z4": "b2",
    "z5": "b3", "z6": "b3",
    "z7": "b4", "z8": "b4", "z9": "b4",
}


def bell(t: float, center: float, width: float) -> float:
    return math.exp(-((t - center) ** 2) / (2.0 * width * width))


def _r3(x: float) -> float:
    return round(x, 3)


# ------------------------------------------------------------- demand shapes

def zone_demand(i: int) -> "list[float]":
    """kW series for zone i: base + morning peak + midday bump + evening peak,
    clamped to the contract fixture's 10-40 kW window. The b1 zones (i < 3)
    carry a wide late-evening plateau (see module docstring)."""
    out = []
    for t in range(STEPS):
        if i < 3:  # b1 zones: high base, evening plateau into the night
            d = (22.0 + 0.4 * i
                 + 9.0 * bell(t, 29 + i, 6.0)
                 + 5.0 * bell(t, 50, 10.0)
                 + 16.5 * bell(t, 82 + i, 15.0))
        else:      # b2..b4 zones: classic residential double peak
            d = (11.5 + 0.35 * (i - 3)
                 + (7.0 + (i % 3) * 1.5) * bell(t, 29 + (i % 4), 5.5)
                 + 6.0 * bell(t, 50, 11.0)
                 + (11.0 + (i % 3)) * bell(t, 76 + (i % 5), 7.0))
        out.append(_r3(min(max(d, 10.0), 40.0)))
    return out


# ------------------------------------------------------- generation dispatch

def pv_series() -> "list[float]":
    """Midday bell up to the 200-kW rating; tiny tails snapped to 0."""
    out = []
    for t in range(STEPS):
        p = 200.0 * bell(t, 48, 9.5)
        out.append(_r3(p) if p >= 0.05 else 0.0)
    return out


def wind_series() -> "list[float]":
    """Varied: morning + evening wind, calm-ish midday, near-calm at the end
    of the day (keeps the final-step balance inside the golden voltages)."""
    out = []
    for t in range(STEPS):
        w = (120.0 * bell(t, 20, 14.0)
             + 105.0 * bell(t, 77, 10.0)
             + 15.0 * math.sin(2.0 * math.pi * t / STEPS * 5.3 + 1.3))
        out.append(_r3(min(max(w, 0.0), 300.0)))
    return out


def battery_series() -> "list[float]":
    """Signed battery dispatch (contract §3.1: + discharges, − charges):
    soak up part of the midday PV surplus (−30-kW bell at noon), release it
    into the evening peak (+50-kW bell at 18:30). Amplitudes fit inside the
    200-kWh store starting half full (≈ +89 kWh stored midday at charge
    efficiency 0.95, ≈ −157 kWh discharged in the evening — no clamping),
    and the tails snap to 0 so the final step (t=95) dispatches exactly
    0 kW, leaving the calibrated golden slack band untouched."""
    out = []
    for t in range(STEPS):
        p = -30.0 * bell(t, 48, 5.0) + 50.0 * bell(t, 74, 5.0)
        out.append(_r3(p) if abs(p) >= 0.5 else 0.0)
    return out


# ------------------------------------------------------------------- weather

def weather() -> dict:
    wind_kw = wind_series()
    return {
        "wind_ms": [_r3(3.0 + 9.0 * (w / 300.0) ** (1.0 / 3.0)) for w in wind_kw],
        "ghi_wm2": [_r3(900.0 * bell(t, 48, 9.5)) for t in range(STEPS)],
        "temp_c": [_r3(9.0 + 7.0 * bell(t, 58, 16.0)) for t in range(STEPS)],
    }


# ------------------------------------------------------------------ topology

def topology() -> dict:
    buses = [{"name": f"b{i}", "vn_kv": 0.4} for i in range(5)] \
        + [{"name": "i0", "vn_kv": 0.4}, {"name": "i1", "vn_kv": 0.4}]
    lines = [{"name": f"l{i}{i + 1}", "from_bus": i, "to_bus": i + 1,
              "length_km": 0.3, "std_type": "NAYY 4x150 SE"}
             for i in range(4)] \
        + [{"name": "li01", "from_bus": 5, "to_bus": 6,
            "length_km": 0.1, "std_type": "NAYY 4x150 SE"}]
    native = {
        "grid_structure": {"name": "contract_power_fixture", "f_hz": 50.0,
                           "buses": buses},
        "lines": {"lines": lines, "transformers": []},
        # game-driven elements come from zones/devices; no fixed background
        "load": {"resolution_minutes": 15, "steps": STEPS, "loads": []},
        "generation": {"resolution_minutes": 15, "steps": STEPS,
                       "generation": []},
        "substation": {"resolution_minutes": 15, "steps": STEPS,
                       "substations": []},
    }
    return {
        "contract": "1.2",   # the doc USES a 1.2 device kind (grid_forming)
        "network_kind": "power",
        "name": "contract_power_fixture",
        "steps_per_day": STEPS,
        "native": native,
        "zones": [{"id": zid, "node": bus} for zid, bus in ZONE_BUS.items()]
        + [{"id": "zi", "node": "i1"}],
        "devices": [
            {"id": "slack", "kind": "slack", "node": "b0",
             "params": {"vm_pu": 1.0}},
            {"id": "gen1", "kind": "generator", "node": "b1",
             "params": {"p_max_kw": 500}},
            {"id": "pv1", "kind": "pv", "node": "b3",
             "params": {"p_rated_kw": 200}},
            {"id": "wind1", "kind": "wind", "node": "b4",
             "params": {"p_rated_kw": 300}},
            {"id": "cpl_heat", "kind": "coupling_load", "node": "b2"},
            {"id": "bat1", "kind": "battery", "node": "b2",
             "params": {"e_kwh": 200, "p_max_kw": 100}},
            {"id": "gfi", "kind": "grid_forming", "node": "i0",
             "params": {"vm_pu": 1.0, "e_kwh": 200, "p_max_kw": 100}},
        ],
    }


def main() -> None:
    wind = wind_series()
    bat = battery_series()
    fixture = {
        "topology": topology(),
        "script": {
            "steps": STEPS,
            "dt_s": DT_S,
            "zone_demand_kw": {**{zid: zone_demand(i)
                                  for i, zid in enumerate(ZONE_BUS)},
                               "zi": [20.0] * STEPS},
            "device_setpoints": {
                "gen1": {"p_kw": {"const": 200.0}},
                "pv1": {"p_kw": pv_series()},
                "wind1": {"p_kw": wind},
                "bat1": {"p_kw": bat},
            },
            "weather": weather(),
        },
        "allowed_statuses": ["converged"],
        # Evaluated on the FINAL step (t=95, 23:45): balanced by design —
        # slack band calibrated against a live rtpowerflow run (see git log).
        # bat1 dispatches 0 kW at t=95 (battery_series tails snap to 0), so
        # the pre-battery calibration stays valid; its SoC bound is the
        # contract guarantee soc ∈ [0, 1].
        "golden": {
            **{f"zones.{zid}.supplied": [1.0, 1.0] for zid in ZONE_BUS},
            **{f"zones.{zid}.detail.v_pu": [0.93, 1.02] for zid in ZONE_BUS},
            "devices.gen1.output_kw": [199.0, 201.0],
            "devices.pv1.output_kw": [-0.01, 0.01],
            "devices.wind1.output_kw": [wind[-1] - 0.01, wind[-1] + 0.01],
            "devices.cpl_heat.output_kw": [-0.01, 0.01],
            "devices.bat1.output_kw": [-0.01, 0.01],
            "devices.bat1.soc": [0.0, 1.0],
            "devices.slack.output_kw": [-80.0, 60.0],
            # the drained island former still supplies its zone (report,
            # never enforce): flow = demand + line losses, soc pinned empty
            "zones.zi.supplied": [1.0, 1.0],
            "zones.zi.detail.v_pu": [0.93, 1.02],
            "devices.gfi.output_kw": [19.0, 22.0],
            "devices.gfi.soc": [0.0, 0.005],
        },
        # Evaluated by the GAME's cosim e2e at the same step — but with live
        # cross-network coupling: the heat fixture's slack CHP feeds its
        # realized -0.5·q_th (≈ -30..-60 kW, heat-demand-driven) into
        # cpl_heat@b2, shifting voltages and the slack balance. Sanity bands,
        # not pins (ROADMAP Phase 2 acceptance: "golden ranges").
        "golden_coupled": {
            **{f"zones.{zid}.supplied": [1.0, 1.0] for zid in ZONE_BUS},
            **{f"zones.{zid}.detail.v_pu": [0.90, 1.10] for zid in ZONE_BUS},
            "devices.gen1.output_kw": [199.0, 201.0],
            "devices.pv1.output_kw": [-0.01, 0.01],
            "devices.wind1.output_kw": [wind[-1] - 0.01, wind[-1] + 0.01],
            "devices.cpl_heat.output_kw": [-90.0, -10.0],
            "devices.bat1.output_kw": [-0.01, 0.01],
            "devices.bat1.soc": [0.0, 1.0],
            "devices.slack.output_kw": [-170.0, 60.0],
            # coupling shifts only the MAIN component; the island is galvanic
            "zones.zi.supplied": [1.0, 1.0],
            "zones.zi.detail.v_pu": [0.90, 1.10],
            "devices.gfi.output_kw": [19.0, 22.0],
            "devices.gfi.soc": [0.0, 0.005],
        },
        "patch_probe": {"id": "gen_probe", "kind": "generator", "node": "b2",
                        "params": {"p_max_kw": 100}},
        # hand-added probe keys (Phase-7b contract expansion) — kept HERE so
        # regeneration never drops them again (the generator was stale once)
        "signed_demand_probe": {"zone": "z0", "value": -50.0,
                                "slack_id": "slack",
                                "min_import_drop": 40.0},
        "clamp_probe": {"device": "bat1", "p_kw": 99999.0,
                        "bound_kw": 100.0},
        "coupling_probe": {"device": "cpl_heat", "p_kw": 123.0,
                           "tolerance": 5.0},
        "soc_probe": {"device": "bat1", "soc": 0.33, "tolerance": 0.25},
        "require_edges": True,
        # contract 1.2: the exhausted island former must carry the
        # storage_empty violation at the final step, and reset must honor
        # an explicit soc replay on a grid_forming device
        "grid_forming_probe": {"device": "gfi",
                               "expect_empty_violation": True,
                               "soc": 0.4, "tolerance": 0.05},
    }
    OUT.write_text(json.dumps(fixture, indent=1) + "\n", encoding="utf-8",
                   newline="\n")
    total0 = sum(zone_demand(i)[0] for i in range(10))
    total95 = sum(zone_demand(i)[-1] for i in range(10))
    # battery SoC dry run (backend physics: charge eff 0.95, discharge
    # lossless, start at 0.5 * e_kwh) — proves the series never clamps
    soc, lo, hi = 100.0, 100.0, 100.0
    for p in bat:
        soc += (-p * 0.95 if p < 0 else -p) * DT_S / 3600.0
        lo, hi = min(lo, soc), max(hi, soc)
    print(f"wrote {OUT}")
    print(f"  zone demand: t=0 {total0:.1f} kW · t=95 {total95:.1f} kW")
    print(f"  wind: t=0 {wind[0]:.1f} kW · t=95 {wind[-1]:.1f} kW")
    print(f"  battery: t=95 {bat[-1]:.1f} kW · SoC {lo:.1f}..{hi:.1f} kWh "
          f"(bounds 0/200) · final {soc:.1f} kWh")


if __name__ == "__main__":
    main()
