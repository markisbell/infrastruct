"""In-memory reference implementation of the SimGames co-simulation contract v1.

Implements the complete ``/gb/*`` surface of ``docs/contract/v1.md`` without any
physics: step results are fabricated but shape- and semantics-correct (idempotent
last-``t`` cache, out-of-order HTTP 409 / WS error frame, coupling-value sign
conventions, sample-and-hold zone demand, clamping violations).

Used by the contract test suite (``tests/contract/test_contract.py``) as the
reference target, and later as the game's unit-test backend (ROADMAP §6.2) —
keep it dependency-light and free of test-specific hacks.

Run::

    python -m mock_backend        # env: MOCK_HOST (default 127.0.0.1),
                                  #      MOCK_PORT (default 8025)
"""

from __future__ import annotations

import json
import os
import time
from dataclasses import dataclass, field
from typing import Any, Optional

from fastapi import FastAPI, HTTPException, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import JSONResponse

CONTRACT_VERSION = "1.0"
BACKEND_NAME = "mock"
API_VERSION = "0.1.0"

NETWORK_KINDS = ("power", "heat", "water")
DEVICE_KINDS = (
    "slack", "generator", "pv", "wind", "coupling_load",
    "chp", "heat_pump", "boiler", "battery", "storage_heat",
)

# Fabricated per-network zone quality detail (contract v1 §4: v1 mapping is
# converged -> supplied 1.0 with quality figures in `detail`).
ZONE_DETAIL = {
    "power": {"v_pu": 0.98},
    "heat": {"t_supply_c": 75.0, "dp_bar": 0.8},
    "water": {"p_bar": 4.2},
}

app = FastAPI(title="SimGames contract v1 mock backend")


# --------------------------------------------------------------------------- state

@dataclass
class _NetState:
    doc: dict
    network_kind: str
    zones: "dict[str, dict]"                 # zone id -> zone spec
    devices: "dict[str, dict]"               # device id -> {kind, node, params}
    zone_demand: "dict[str, float]"          # sample-and-hold, defaults 0.0
    held_setpoints: "dict[str, dict]" = field(default_factory=dict)


_STATE: Optional[_NetState] = None
_LAST_T: Optional[int] = None
_LAST_RESULT: Optional[dict] = None


# --------------------------------------------------------------------- validation

def _as_int(v):
    """JSON-semantics integer: real int or zero-fraction float (JSON Schema
    "integer" — Godot's JSON layer sends 96 as 96.0). None if not integral."""
    if isinstance(v, bool):
        return None
    if isinstance(v, int):
        return v
    if isinstance(v, float) and v.is_integer():
        return int(v)
    return None


def _bad(msg: str) -> None:
    raise HTTPException(status_code=400, detail=msg)


async def _json_body(request: Request) -> Any:
    try:
        return json.loads(await request.body())
    except json.JSONDecodeError:
        _bad("body is not valid JSON")


def _is_num(v: Any) -> bool:
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def _validate_topology(doc: Any) -> None:
    """Minimal structural validation per docs/contract/schemas/topology.schema.json."""
    if not isinstance(doc, dict):
        _bad("topology document must be a JSON object")
    for key in ("contract", "network_kind", "name", "steps_per_day", "native", "zones", "devices"):
        if key not in doc:
            _bad(f"topology document missing required key '{key}'")
    if doc["contract"] != CONTRACT_VERSION:
        _bad(f"unsupported contract version {doc['contract']!r} (this backend speaks {CONTRACT_VERSION})")
    if doc["network_kind"] not in NETWORK_KINDS:
        _bad(f"unknown network_kind {doc['network_kind']!r}")
    if not isinstance(doc["name"], str) or not doc["name"]:
        _bad("'name' must be a non-empty string")
    spd = _as_int(doc["steps_per_day"])
    if spd is None or not (24 <= spd <= 1440):
        _bad("'steps_per_day' must be an integer in [24, 1440]")
    doc["steps_per_day"] = spd  # canonical int downstream
    if not isinstance(doc["native"], dict):
        _bad("'native' must be an object")
    if not isinstance(doc["zones"], list):
        _bad("'zones' must be an array")
    seen: set = set()
    for i, zone in enumerate(doc["zones"]):
        if not isinstance(zone, dict) or not isinstance(zone.get("id"), str) or not zone["id"]:
            _bad(f"zones[{i}] must be an object with a non-empty string 'id'")
        if zone["id"] in seen:
            _bad(f"duplicate zone id {zone['id']!r}")
        seen.add(zone["id"])
    if not isinstance(doc["devices"], list):
        _bad("'devices' must be an array")
    seen = set()
    for i, dev in enumerate(doc["devices"]):
        err = _device_error(dev)
        if err:
            _bad(f"devices[{i}]: {err}")
        if dev["id"] in seen:
            _bad(f"duplicate device id {dev['id']!r}")
        seen.add(dev["id"])


def _device_error(dev: Any) -> Optional[str]:
    """Return an error string if `dev` is not a valid device spec, else None."""
    if not isinstance(dev, dict):
        return "device must be an object"
    if not isinstance(dev.get("id"), str) or not dev["id"]:
        return "device needs a non-empty string 'id'"
    if dev.get("kind") not in DEVICE_KINDS:
        return f"unknown device kind {dev.get('kind')!r}"
    if "params" in dev and not isinstance(dev["params"], dict):
        return "'params' must be an object"
    return None


# ------------------------------------------------------------------ fabrication

def _fabricate(req: dict) -> dict:
    """Fabricate a plausible converged step result for the current network."""
    assert _STATE is not None
    started = time.perf_counter()
    state = _STATE

    # Sample-and-hold zone demand (contract §4: missing zone keeps previous value).
    for zid, entry in (req.get("zone_demand") or {}).items():
        if zid in state.zone_demand and isinstance(entry, dict) and _is_num(entry.get("value")):
            state.zone_demand[zid] = max(0.0, float(entry["value"]))

    # Hold device setpoints, too — devices echo their latest setpoint.
    for did, sp in (req.get("device_setpoints") or {}).items():
        if did in state.devices and isinstance(sp, dict):
            held = state.held_setpoints.setdefault(did, {})
            held.update({k: float(v) for k, v in sp.items() if _is_num(v)})

    # coupling_in routes onto coupling_load devices (positive = draws from this net).
    for did, entry in (req.get("coupling_in") or {}).items():
        if did in state.devices and state.devices[did]["kind"] == "coupling_load" \
                and isinstance(entry, dict) and _is_num(entry.get("p_kw")):
            state.held_setpoints.setdefault(did, {})["p_kw"] = float(entry["p_kw"])

    violations: "list[dict]" = []
    devices_out: "dict[str, dict]" = {}
    coupling_out: "dict[str, dict]" = {}
    total_production = 0.0
    slack_ids: "list[str]" = []

    for did, dev in state.devices.items():
        kind = dev["kind"]
        params = dev.get("params") or {}
        sp = state.held_setpoints.get(did, {})

        if kind == "slack":
            slack_ids.append(did)  # filled in after the balance is known
            continue

        if kind in ("generator", "pv", "wind"):
            requested = float(sp.get("p_kw", 0.0))
            cap = params.get("p_max_kw" if kind == "generator" else "p_rated_kw")
            p = max(requested, 0.0)
            if _is_num(cap):
                p = min(p, float(cap))
            if p != requested:
                violations.append({"element": f"device:{did}", "kind": "clamped",
                                   "severity": "info", "value": requested})
            devices_out[did] = {"output_kw": p, "soc": None, "detail": {}}
            total_production += p

        elif kind == "coupling_load":
            p = float(sp.get("p_kw", 0.0))
            devices_out[did] = {"output_kw": p, "soc": None, "detail": {}}
            total_production -= p  # it draws from this network

        elif kind == "chp":
            q = max(float(sp.get("q_kw", 0.0)), 0.0)
            pq_ratio = float(params.get("pq_ratio", 0.5))
            devices_out[did] = {"output_kw": q, "soc": None, "detail": {}}
            # Production feeds the power grid: load convention, negative = feeds (spec §3.1).
            coupling_out[did] = {"p_el_kw": -pq_ratio * q}
            total_production += q

        elif kind == "heat_pump":
            q = max(float(sp.get("q_kw", 0.0)), 0.0)
            eta_g = float(params.get("eta_g", 0.5))
            t_cold = float(params.get("t_cold_source", 10.0))
            t_supply = 70.0
            lift = t_supply - t_cold
            cop = eta_g * (t_supply + 273.15) / lift if lift > 1e-6 else 3.0
            cop = max(cop, 1.0)
            devices_out[did] = {"output_kw": q, "soc": None, "detail": {"cop": round(cop, 3)}}
            # Draws from the power grid: positive (spec §3.1).
            coupling_out[did] = {"p_el_kw": q / cop if q else 0.0}
            total_production += q

        elif kind == "boiler":
            q = max(float(sp.get("q_kw", 0.0)), 0.0)
            eta = float(params.get("eta", 0.9))
            fuel = q / eta if eta > 0 else q
            devices_out[did] = {"output_kw": q, "soc": None, "detail": {"p_fuel_kw": round(fuel, 6)}}
            total_production += q

        elif kind in ("battery", "storage_heat"):
            # Declared in v1, implemented in Phases 3/4 — idle with a plausible SoC.
            devices_out[did] = {"output_kw": 0.0, "soc": 0.5, "detail": {}}

    total_demand = sum(state.zone_demand[zid] for zid in state.zones)
    for did in slack_ids:
        # Slack balances the network: import positive (spec §3.1).
        devices_out[did] = {"output_kw": round(total_demand - total_production, 6),
                            "soc": None, "detail": {}}

    zones_out = {zid: {"supplied": 1.0, "detail": dict(ZONE_DETAIL[state.network_kind])}
                 for zid in state.zones}

    return {
        "t": req["t"],
        "status": "converged",
        "solve_ms": round(max((time.perf_counter() - started) * 1000.0, 0.001), 3),
        "zones": zones_out,
        "devices": devices_out,
        "coupling_out": coupling_out,
        "violations": violations,
    }


def _step(req: Any) -> "tuple[int, dict]":
    """Shared step logic for HTTP POST /gb/step and WS /gb/ws.

    Returns (http_status, payload): 200 with a step result, 400 with {detail},
    or 409 with the out-of-order error frame (contract §4).
    """
    global _LAST_T, _LAST_RESULT
    if _STATE is None:
        return 400, {"detail": "no network loaded — POST /gb/net/reset first"}
    if not isinstance(req, dict):
        return 400, {"detail": "step request must be a JSON object"}
    t = _as_int(req.get("t"))
    if t is None or t < 0:
        return 400, {"detail": "step request needs an integer 't' >= 0"}

    if _LAST_T is not None:
        if t == _LAST_T:
            # Idempotent re-send: cached result, no re-solve (contract §0.3).
            return 200, _LAST_RESULT  # type: ignore[return-value]
        if t != _LAST_T + 1:
            return 409, {"t": t, "status": "error", "error": "out_of_order",
                         "expected": [_LAST_T, _LAST_T + 1]}

    result = _fabricate(req)
    _LAST_T = t
    _LAST_RESULT = result
    return 200, result


# -------------------------------------------------------------------- endpoints

@app.get("/health")
async def health() -> dict:
    return {"status": "ok", "net_loaded": _STATE is not None, "last_step": _LAST_T}


@app.get("/gb/version")
async def version() -> dict:
    return {
        "contract": CONTRACT_VERSION,
        "backend": BACKEND_NAME,
        "api": API_VERSION,
        "solver": "in-memory mock (no physics)",
        "external_clock": True,
    }


@app.post("/gb/net/reset")
async def net_reset(request: Request) -> dict:
    global _STATE, _LAST_T, _LAST_RESULT
    doc = await _json_body(request)
    _validate_topology(doc)
    started = time.perf_counter()
    _STATE = _NetState(
        doc=doc,
        network_kind=doc["network_kind"],
        zones={z["id"]: z for z in doc["zones"]},
        devices={d["id"]: {"kind": d["kind"], "node": d.get("node"),
                           "params": dict(d.get("params") or {})}
                 for d in doc["devices"]},
        zone_demand={z["id"]: 0.0 for z in doc["zones"]},
    )
    # A reset clears last_t: the next step may carry any t (contract §3.1).
    _LAST_T = None
    _LAST_RESULT = None
    # Throwaway warmup solve, mirroring the real backends' JIT warmup (ADR-003).
    _fabricate({"t": 0})
    warmup_ms = round(max((time.perf_counter() - started) * 1000.0, 0.001), 3)
    return {
        "ok": True,
        "network_kind": _STATE.network_kind,
        "n_zones": len(_STATE.zones),
        "n_devices": len(_STATE.devices),
        "warmup_solve_ms": warmup_ms,
        "warnings": [],
    }


@app.post("/gb/net/patch")
async def net_patch(request: Request) -> dict:
    ops = await _json_body(request)
    if _STATE is None:
        _bad("no network loaded — POST /gb/net/reset first")
    if not isinstance(ops, list):
        _bad("patch body must be a JSON array of ops")
    applied: "list[str]" = []
    errors: "list[dict]" = []
    for i, op in enumerate(ops):
        try:
            applied.append(_apply_op(op))
        except ValueError as exc:
            # Tolerant per entry: earlier ops stay applied (contract §3.2).
            errors.append({"index": i, "error": str(exc)})
    return {"applied": applied, "errors": errors}


def _apply_op(op: Any) -> str:
    assert _STATE is not None
    if not isinstance(op, dict):
        raise ValueError("op must be an object")
    name = op.get("op")
    if name == "add_device":
        dev = op.get("device")
        err = _device_error(dev)
        if err:
            raise ValueError(err)
        if dev["id"] in _STATE.devices:
            raise ValueError(f"duplicate device {dev['id']}")
        _STATE.devices[dev["id"]] = {"kind": dev["kind"], "node": dev.get("node"),
                                     "params": dict(dev.get("params") or {})}
        return dev["id"]
    if name == "remove_device":
        did = op.get("id")
        if not isinstance(did, str) or did not in _STATE.devices:
            raise ValueError(f"unknown device {did}")
        del _STATE.devices[did]
        _STATE.held_setpoints.pop(did, None)
        return did
    if name == "set_device":
        did = op.get("id")
        if not isinstance(did, str) or did not in _STATE.devices:
            raise ValueError(f"unknown device {did}")
        params = op.get("params")
        if not isinstance(params, dict):
            raise ValueError("set_device needs a 'params' object")
        _STATE.devices[did]["params"].update(params)
        return did
    raise ValueError(f"unknown op {name!r}")


@app.post("/gb/step")
async def step_http(request: Request):
    req = await _json_body(request)
    status, payload = _step(req)
    if status == 200:
        return payload
    return JSONResponse(status_code=status, content=payload)


@app.get("/gb/result/latest")
async def result_latest() -> dict:
    if _LAST_RESULT is None:
        raise HTTPException(status_code=404, detail="no step result yet")
    return _LAST_RESULT


@app.websocket("/gb/ws")
async def step_ws(websocket: WebSocket) -> None:
    await websocket.accept()
    try:
        while True:
            raw = await websocket.receive_text()
            try:
                req = json.loads(raw)
            except json.JSONDecodeError:
                await websocket.send_text(json.dumps(
                    {"status": "error", "error": "bad_request",
                     "detail": "frame is not valid JSON"}))
                continue
            status, payload = _step(req)
            if status == 409 or status == 200:
                # 409 payload already is the out-of-order error frame (contract §4).
                await websocket.send_text(json.dumps(payload))
            else:
                t = req.get("t") if isinstance(req, dict) else None
                await websocket.send_text(json.dumps(
                    {"t": t, "status": "error", "error": "bad_request",
                     "detail": payload.get("detail")}))
    except WebSocketDisconnect:
        pass


# ------------------------------------------------------------------------- main

def main() -> None:
    import uvicorn

    host = os.environ.get("MOCK_HOST", "127.0.0.1")
    port = int(os.environ.get("MOCK_PORT", "8025"))
    uvicorn.run(app, host=host, port=port, log_level="warning")


if __name__ == "__main__":
    main()
