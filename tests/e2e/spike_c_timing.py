"""Spike C timing: solver step cost on reference grids of game-relevant size.

Uses rtpowerflow's reference feeders (pandapower-shipped IEEE/CIGRE/Kerber)
to measure Simulator.run_step wall time — the solver share of the co-sim
step budget (ROADMAP §6.3: p99 round-trip <= 50 ms).
"""
from __future__ import annotations

import json
import statistics
import sys
import time

from netzsim.data_loader import input_data_from_dicts
from netzsim.reference_import import REFERENCE_GRIDS, convert_reference
from netzsim.simulator import Simulator

N_STEPS = 100


def bench(grid_id: str) -> dict:
    docs = convert_reference(grid_id, steps=1440).as_files()
    data = input_data_from_dicts(
        grid=docs["grid_structure.json"],
        lines=docs["lines.json"],
        load=docs["load.json"],
        generation=docs["generation.json"],
        substation=docs["substation.json"],
    )
    sim = Simulator(data)
    times_ms: list[float] = []
    for step in range(N_STEPS):
        t0 = time.perf_counter()
        res = sim.run_step(step * 14)  # spread across the day
        times_ms.append((time.perf_counter() - t0) * 1000.0)
        if not res.converged:
            return {"grid": grid_id, "error": f"step {step} did not converge"}
    times_ms.sort()
    return {
        "grid": grid_id,
        "n_bus": len(sim.net.bus),
        "n_line": len(sim.net.line),
        "avg_ms": round(statistics.fmean(times_ms), 2),
        "p50_ms": round(times_ms[len(times_ms) // 2], 2),
        "p99_ms": round(times_ms[min(int(len(times_ms) * 0.99), len(times_ms) - 1)], 2),
        "worst_ms": round(times_ms[-1], 2),
    }


if __name__ == "__main__":
    wanted = sys.argv[1:] or ["ieee_33bw", "cigre_mv", "kerber_vorstadt_a"]
    available = list(REFERENCE_GRIDS)
    print("available reference grids:", available)
    results = [bench(g) for g in wanted if g in available]
    print("SPIKE_C_TIMING", json.dumps(results, indent=2))
