"""Spike B stub backend: measures pure transport+serialization latency of the
game<->solver bridge. Implements the /gb/step shape from ROADMAP §5 with
realistic payload sizes (~100 zones, 20 devices) but zero solver work.

Run:  uvicorn stub_backend:app --host 127.0.0.1 --port 8123 --log-level warning
"""

from fastapi import FastAPI, WebSocket, WebSocketDisconnect

app = FastAPI()

N_ZONES = 100
N_DEVICES = 20


def make_result(t: int) -> dict:
    return {
        "t": t,
        "status": "converged",
        "zones": {
            f"z{i}": {"supplied": 1.0, "v_pu": 0.98 + (i % 5) * 0.004}
            for i in range(N_ZONES)
        },
        "devices": {
            f"d{i}": {"output": 100.0 + i, "soc": 0.5} for i in range(N_DEVICES)
        },
        "coupling_out": {"chp1": 250.0},
        "violations": [],
    }


@app.get("/gb/health")
def health() -> dict:
    return {"status": "ok", "net_loaded": True, "last_step": 0}


@app.post("/gb/step")
def step(body: dict) -> dict:
    return make_result(body.get("t", 0))


@app.websocket("/ws")
async def ws_step(ws: WebSocket) -> None:
    await ws.accept()
    try:
        while True:
            body = await ws.receive_json()
            await ws.send_json(make_result(body.get("t", 0)))
    except WebSocketDisconnect:
        pass
