"""SimGames co-simulation contract v1 test suite — backend-agnostic (ROADMAP §6.2).

Runs the same assertions against every backend registered in ``backends.json``
whose fixture file and working directory exist (others are skipped with a
reason). Per backend, one test spawns the process, waits for ``/health``, and
asserts contract v1 behavior IN ORDER:

  a. /gb/version handshake (contract major 1, external_clock true)
  b. POST /gb/net/reset with the fixture topology
  c. the fixture script, stepped over WebSocket /gb/ws, every result validated
     against docs/contract/schemas/step-result.schema.json; when a result
     carries the optional 'edges' field (contract 1.1) every entry must have a
     numeric loading_percent >= 0
  d. idempotent re-send of the last step over HTTP; out-of-order -> 409 / WS
     error frame
  e. GET /gb/result/latest equals the last result
  f. golden ranges on the final result
  g. /gb/net/patch add/remove round-trip + tolerant unknown-id error

Spec: docs/contract/v1.md (authoritative). Fixture format: see README.md here.
"""

from __future__ import annotations

import json
import os
import signal
import socket
import subprocess
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

import jsonschema
import pytest
from websocket import create_connection

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parent.parent
SCHEMA_DIR = REPO_ROOT / "docs" / "contract" / "schemas"
STEP_RESULT_SCHEMA = SCHEMA_DIR / "step-result.schema.json"
STEP_REQUEST_SCHEMA = SCHEMA_DIR / "step-request.schema.json"
TOPOLOGY_SCHEMA = SCHEMA_DIR / "topology.schema.json"


def _schema_validator(path: Path) -> jsonschema.Draft202012Validator:
    return jsonschema.Draft202012Validator(
        json.loads(path.read_text(encoding="utf-8")))


def _assert_schema(validator: "jsonschema.Draft202012Validator",
                   obj: Any, label: str) -> None:
    errors = sorted(validator.iter_errors(obj), key=str)
    assert not errors, (
        f"{label} violates its schema:\n" +
        "\n".join(f"  - {e.json_path}: {e.message}" for e in errors))

HEALTH_TIMEOUT_S = 120.0   # numba JIT imports can take a while on first spawn
HTTP_TIMEOUT_S = 60.0
WS_TIMEOUT_S = 60.0


# ------------------------------------------------------------------ registry

def _python_path(rel: str) -> Path:
    # backends.json carries the Windows venv layout; translate on POSIX.
    # abspath, NOT resolve(): a uv venv's bin/python is a symlink to the base
    # interpreter, and following it would spawn OUTSIDE the venv (no deps).
    if os.name != "nt" and "/Scripts/" in rel:
        rel = rel.replace("/Scripts/", "/bin/").removesuffix(".exe")
    return Path(os.path.abspath(HERE / rel))


def _load_params() -> "list[Any]":
    registry = json.loads((HERE / "backends.json").read_text(encoding="utf-8"))
    params = []
    for entry in registry["backends"]:
        cwd = (HERE / entry["cwd"]).resolve()
        fixture = (HERE / entry["fixture"]).resolve()
        python = _python_path(entry["python"])
        reason = None
        if not fixture.is_file():
            reason = f"fixture not found: {fixture}"
        elif not cwd.is_dir():
            reason = f"backend cwd not found: {cwd}"
        elif not python.is_file():
            reason = f"python interpreter not found: {python}"
        marks = [pytest.mark.skip(reason=reason)] if reason else []
        params.append(pytest.param(entry, id=entry["id"], marks=marks))
    return params


# ------------------------------------------------------------------- helpers

def _http_json(method: str, url: str, body: Any = None) -> "tuple[int, Any]":
    """JSON request via stdlib; returns (status, decoded body) even on 4xx/5xx."""
    data = None
    headers = {"Accept": "application/json"}
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT_S) as resp:
            raw = resp.read().decode("utf-8")
            return resp.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as err:
        raw = err.read().decode("utf-8", errors="replace")
        try:
            return err.code, json.loads(raw)
        except json.JSONDecodeError:
            return err.code, raw


def _port_open(port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.settimeout(0.5)
        return sock.connect_ex(("127.0.0.1", port)) == 0


def _kill_tree(proc: subprocess.Popen) -> None:
    if proc.poll() is not None:
        return
    if os.name == "nt":
        subprocess.run(["taskkill", "/T", "/F", "/PID", str(proc.pid)],
                       capture_output=True)
    else:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            proc.kill()
    try:
        proc.wait(timeout=15)
    except subprocess.TimeoutExpired:
        proc.kill()


def _log_tail(log_path: Path, n: int = 40) -> str:
    try:
        lines = log_path.read_text(encoding="utf-8", errors="replace").splitlines()
        return "\n".join(lines[-n:])
    except OSError:
        return "<no log captured>"


def _wait_health(base: str, proc: subprocess.Popen, log_path: Path) -> None:
    deadline = time.monotonic() + HEALTH_TIMEOUT_S
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            pytest.fail(
                f"backend exited with code {proc.returncode} before /health came up.\n"
                f"--- log tail ---\n{_log_tail(log_path)}")
        try:
            status, _ = _http_json("GET", base + "/health")
            if status == 200:
                return
        except (urllib.error.URLError, ConnectionError, TimeoutError, OSError):
            pass
        time.sleep(0.25)
    _kill_tree(proc)
    pytest.fail(
        f"/health not reachable within {HEALTH_TIMEOUT_S:.0f} s.\n"
        f"--- log tail ---\n{_log_tail(log_path)}")


def _series_value(spec: Any, t: int, steps: int, what: str) -> float:
    """Fixture series: either a JSON array of `steps` values or {"const": v}."""
    if isinstance(spec, dict):
        assert "const" in spec, f"{what}: series object must have a 'const' key"
        return spec["const"]
    assert isinstance(spec, list) and len(spec) == steps, \
        f"{what}: series must be a list of exactly {steps} values or {{'const': v}}"
    return spec[t]


def _build_step_request_raw(script: dict, t: int) -> dict:
    return _floatify(_build_step_request(script, t))


def _build_step_request(script: dict, t: int) -> dict:
    steps = script["steps"]
    req: dict = {"t": t, "dt_s": script["dt_s"]}
    weather = {key: _series_value(spec, t, steps, f"weather.{key}")
               for key, spec in (script.get("weather") or {}).items()}
    if weather:
        req["weather"] = weather
    zone_demand = {zid: {"value": _series_value(spec, t, steps, f"zone_demand_kw.{zid}")}
                   for zid, spec in (script.get("zone_demand_kw") or {}).items()}
    if zone_demand:
        req["zone_demand"] = zone_demand
    setpoints = {}
    for did, keys in (script.get("device_setpoints") or {}).items():
        setpoints[did] = {key: _series_value(spec, t, steps, f"device_setpoints.{did}.{key}")
                          for key, spec in keys.items()}
    if setpoints:
        req["device_setpoints"] = setpoints
    return req


def _floatify(obj: Any) -> Any:
    """Recursively turn every int into a float — the wire shape produced by
    JSON layers without an integer type (Godot serializes 96 as 96.0). The
    contract's JSON-Schema "integer" accepts zero-fraction floats, so every
    backend MUST tolerate this (regression: game /gb/net/reset was 400'd)."""
    if isinstance(obj, bool):
        return obj
    if isinstance(obj, int):
        return float(obj)
    if isinstance(obj, list):
        return [_floatify(v) for v in obj]
    if isinstance(obj, dict):
        return {k: _floatify(v) for k, v in obj.items()}
    return obj


def _minus_solve_ms(result: Any) -> Any:
    stripped = dict(result)
    stripped.pop("solve_ms", None)
    return stripped


def _canon(result: Any) -> str:
    """Canonical JSON text of a result minus solve_ms — 'byte-equal' comparison."""
    return json.dumps(_minus_solve_ms(result), sort_keys=True)


def _resolve_dotted(obj: Any, dotted: str) -> Any:
    cur = obj
    for part in dotted.split("."):
        assert isinstance(cur, dict) and part in cur, \
            f"golden path {dotted!r}: {part!r} not found (got keys " \
            f"{sorted(cur.keys()) if isinstance(cur, dict) else type(cur).__name__})"
        cur = cur[part]
    return cur


# ---------------------------------------------------------------------- test

@pytest.mark.parametrize("entry", _load_params())
def test_contract(entry: dict, tmp_path: Path) -> None:
    cwd = (HERE / entry["cwd"]).resolve()
    python = _python_path(entry["python"])
    fixture = json.loads((HERE / entry["fixture"]).resolve().read_text(encoding="utf-8"))
    port = entry["port"]
    base = f"http://127.0.0.1:{port}"

    assert not _port_open(port), \
        f"port {port} already in use — stale backend process? Free it before running."

    env = {**os.environ, **{k: str(v) for k, v in (entry.get("env") or {}).items()}}
    log_path = tmp_path / f"{entry['id']}.log"
    popen_kwargs: dict = {}
    if os.name != "nt":
        popen_kwargs["start_new_session"] = True  # killable process group
    with open(log_path, "wb") as log_file:
        proc = subprocess.Popen(
            [str(python), "-m", entry["module"]],
            cwd=str(cwd), env=env,
            stdout=log_file, stderr=subprocess.STDOUT,
            **popen_kwargs)
        ws = None
        try:
            _wait_health(base, proc, log_path)

            # --- a. version handshake -------------------------------------
            status, version = _http_json("GET", base + "/gb/version")
            assert status == 200, f"/gb/version -> HTTP {status}: {version}"
            contract = str(version.get("contract", ""))
            major, _, minor = contract.partition(".")
            assert major == "1" and minor.isdigit(), \
                f"contract version {contract!r} does not satisfy major=1 (v1.md §2)"
            assert version.get("external_clock") is True, \
                f"backend not in external-clock puppet mode: {version}"

            # --- b. reset with the fixture topology ------------------------
            # sent through _floatify: every int arrives as a zero-fraction
            # float, exactly like Godot's JSON layer produces (regression pin).
            # The wire shape must satisfy topology.schema.json — the schemas
            # themselves are under test here, not just the backends.
            topology = fixture["topology"]
            wire_topology = _floatify(topology)
            _assert_schema(_schema_validator(TOPOLOGY_SCHEMA), wire_topology,
                           "fixture topology (floatified wire shape)")
            status, reset = _http_json("POST", base + "/gb/net/reset",
                                       wire_topology)
            assert status == 200, f"/gb/net/reset -> HTTP {status}: {reset}"
            assert reset.get("ok") is True, f"reset not ok: {reset}"
            assert reset.get("n_zones") == len(topology["zones"]), \
                f"n_zones {reset.get('n_zones')} != {len(topology['zones'])}"
            assert reset.get("n_devices") == len(topology["devices"]), \
                f"n_devices {reset.get('n_devices')} != {len(topology['devices'])}"
            warmup = reset.get("warmup_solve_ms")
            assert isinstance(warmup, (int, float)) and not isinstance(warmup, bool), \
                f"warmup_solve_ms missing/not numeric: {reset}"

            # --- c. scripted stepping over WebSocket -----------------------
            validator = _schema_validator(STEP_RESULT_SCHEMA)
            request_validator = _schema_validator(STEP_REQUEST_SCHEMA)
            script = fixture["script"]
            allowed = fixture["allowed_statuses"]
            ws = create_connection(f"ws://127.0.0.1:{port}/gb/ws", timeout=WS_TIMEOUT_S)
            last_req: dict = {}
            last_result: dict = {}
            for t in range(script["steps"]):
                # Godot-wire shape: ints arrive as zero-fraction floats;
                # every request we send must itself satisfy its schema
                req = _build_step_request_raw(script, t)
                _assert_schema(request_validator, req, f"step-request t={t}")
                ws.send(json.dumps(req))
                result = json.loads(ws.recv())
                assert result.get("t") == t, \
                    f"step {t}: t echo mismatch, got {result.get('t')} ({result})"
                assert result.get("status") in allowed, \
                    f"step {t}: status {result.get('status')!r} not in {allowed}"
                errors = sorted(validator.iter_errors(result), key=str)
                assert not errors, (
                    f"step {t}: result violates step-result.schema.json:\n" +
                    "\n".join(f"  - {e.json_path}: {e.message}" for e in errors))
                # edges (optional since contract 1.1): when present, every
                # entry must carry a numeric loading_percent >= 0 (v1.md §4)
                if "edges" in result:
                    assert isinstance(result["edges"], dict), \
                        f"step {t}: 'edges' must be an object: {result['edges']!r}"
                    for eid, edge in result["edges"].items():
                        lp = edge.get("loading_percent") if isinstance(edge, dict) else None
                        assert isinstance(lp, (int, float)) and not isinstance(lp, bool) \
                            and lp >= 0, (
                            f"step {t}: edges[{eid!r}] needs a numeric "
                            f"loading_percent >= 0, got {edge!r}")
                last_req, last_result = req, result

            # --- d. idempotency + out-of-order -----------------------------
            status, resend = _http_json("POST", base + "/gb/step", last_req)
            assert status == 200, f"idempotent re-send -> HTTP {status}: {resend}"
            assert _canon(resend) == _canon(last_result), (
                "idempotent re-send differs from cached result (minus solve_ms):\n"
                f"  resent: {_canon(resend)}\n  cached: {_canon(last_result)}")

            out_of_order = dict(last_req)
            out_of_order["t"] = last_req["t"] + 5
            status, body = _http_json("POST", base + "/gb/step", out_of_order)
            assert status == 409, \
                f"out-of-order t over HTTP must be 409, got {status}: {body}"

            ws.send(json.dumps(out_of_order))
            frame = json.loads(ws.recv())
            assert frame.get("status") == "error", \
                f"out-of-order t over WS must yield a status='error' frame: {frame}"
            assert frame.get("error") == "out_of_order", \
                f"WS error frame must carry error='out_of_order' (v1.md §4): {frame}"
            ws.close()
            ws = None

            # --- e. /gb/result/latest --------------------------------------
            status, latest = _http_json("GET", base + "/gb/result/latest")
            assert status == 200, f"/gb/result/latest -> HTTP {status}: {latest}"
            assert _canon(latest) == _canon(last_result), (
                "/gb/result/latest differs from the last step result (minus solve_ms):\n"
                f"  latest: {_canon(latest)}\n  cached: {_canon(last_result)}")

            # --- f. golden ranges on the final result ----------------------
            for dotted, bounds in (fixture.get("golden") or {}).items():
                lo, hi = bounds
                value = _resolve_dotted(last_result, dotted)
                assert isinstance(value, (int, float)) and not isinstance(value, bool), \
                    f"golden path {dotted!r}: value {value!r} is not numeric"
                assert lo <= value <= hi, \
                    f"golden path {dotted!r}: {value} outside [{lo}, {hi}]"

            # --- f2. signed power zone demand (v1.md §4 power note) --------
            # A strongly negative zone must REDUCE slack import by roughly
            # |old| + |probe| — a backend that clamps negatives to 0 only
            # sheds |old| and fails the min_import_drop separation.
            probe_neg = fixture.get("signed_demand_probe")
            if probe_neg:
                slack_id = probe_neg["slack_id"]
                slack_before = last_result["devices"][slack_id]["output_kw"]
                req = dict(last_req)
                req["t"] = float(last_req["t"]) + 1.0
                req["zone_demand"] = dict(last_req.get("zone_demand") or {})
                req["zone_demand"][probe_neg["zone"]] = {
                    "value": float(probe_neg["value"])}
                _assert_schema(request_validator, req,
                               "signed-demand step-request")
                status, result = _http_json("POST", base + "/gb/step", req)
                assert status == 200, \
                    f"signed-demand step -> HTTP {status}: {result}"
                assert result.get("status") in allowed, (
                    f"signed-demand step: status {result.get('status')!r} "
                    f"not in {allowed} — negative power demand is data, "
                    f"never an error (v1.md §4)")
                _assert_schema(validator, result, "signed-demand step result")
                slack_after = result["devices"][slack_id]["output_kw"]
                drop = slack_before - slack_after
                assert drop >= probe_neg["min_import_drop"], (
                    f"zone {probe_neg['zone']} at {probe_neg['value']} kW "
                    f"only shed {drop:.1f} kW of slack import (need >= "
                    f"{probe_neg['min_import_drop']}) — backend appears to "
                    f"CLAMP signed power demand (v1.md §4 power note)")

            # --- g. patch round-trip + tolerant error ----------------------
            probe = fixture["patch_probe"]
            probe_id = probe["id"]
            status, patched = _http_json(
                "POST", base + "/gb/net/patch",
                [{"op": "add_device", "device": probe}])
            assert status == 200, f"patch add_device -> HTTP {status}: {patched}"
            assert probe_id in patched.get("applied", []), \
                f"add_device {probe_id!r} not applied: {patched}"
            assert patched.get("errors") == [], \
                f"add_device raised errors: {patched}"

            status, patched = _http_json(
                "POST", base + "/gb/net/patch",
                [{"op": "remove_device", "id": probe_id}])
            assert status == 200, f"patch remove_device -> HTTP {status}: {patched}"
            assert probe_id in patched.get("applied", []), \
                f"remove_device {probe_id!r} not applied: {patched}"
            assert patched.get("errors") == [], \
                f"remove_device raised errors: {patched}"

            unknown_id = "__no_such_device__"
            status, patched = _http_json(
                "POST", base + "/gb/net/patch",
                [{"op": "remove_device", "id": unknown_id}])
            assert status == 200, (
                f"patch is tolerant per entry — removing an unknown id must NOT be an "
                f"HTTP error (v1.md §3.2), got {status}: {patched}")
            errors = patched.get("errors")
            assert isinstance(errors, list) and len(errors) == 1, \
                f"expected exactly one error entry for the unknown id: {patched}"
            assert unknown_id in json.dumps(errors[0]), \
                f"error entry does not mention the unknown id: {errors[0]}"
            assert unknown_id not in patched.get("applied", []), \
                f"unknown id listed as applied: {patched}"
        finally:
            if ws is not None:
                try:
                    ws.close()
                except Exception:
                    pass
            _kill_tree(proc)
