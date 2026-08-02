"""FastAPI orchestration server for the PyCore simulator UI."""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any

from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from .runner import (
    DEFAULT_MAX_CYCLES,
    create_session,
    get_heap,
    get_step,
    health_check,
    list_example_sources,
    prune_sessions,
    session_get,
)

STATIC_DIR = Path(__file__).resolve().parents[1] / "web" / "dist"

app = FastAPI(title="PyCore Simulator UI", version="0.1.0")


class SessionCreate(BaseModel):
    source: str = Field(..., min_length=1)
    entry: str = "managed_entry"
    max_cycles: int = DEFAULT_MAX_CYCLES


@app.get("/api/health")
def api_health() -> dict[str, Any]:
    return health_check()


@app.get("/api/examples")
def api_examples() -> list[dict[str, str]]:
    return list_example_sources()


@app.post("/api/sessions")
def api_create_session(body: SessionCreate) -> dict[str, Any]:
    prune_sessions()
    try:
        sess = create_session(
            body.source,
            entry=body.entry,
            max_cycles=body.max_cycles,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    if sess.status == "error":
        return {
            "id": sess.id,
            "status": sess.status,
            "error": sess.error,
        }
    return {
        "id": sess.id,
        "status": sess.status,
        "result": sess.result,
        "step_count": len(sess.steps),
        "event_count": len(sess.events),
        "disasm": sess.disasm,
        "end": sess.end,
    }


@app.get("/api/sessions/{sid}")
def api_get_session(sid: str) -> dict[str, Any]:
    sess = session_get(sid)
    if sess is None:
        raise HTTPException(status_code=404, detail="session not found")
    return {
        "id": sess.id,
        "status": sess.status,
        "error": sess.error,
        "result": sess.result,
        "step_count": len(sess.steps),
        "event_count": len(sess.events),
        "disasm": sess.disasm,
        "end": sess.end,
        "source": sess.source,
        "entry": sess.entry,
        "max_cycles": sess.max_cycles,
    }


@app.get("/api/sessions/{sid}/steps/{n}")
def api_get_step(sid: str, n: int) -> dict[str, Any]:
    sess = session_get(sid)
    if sess is None:
        raise HTTPException(status_code=404, detail="session not found")
    if sess.status != "ready":
        raise HTTPException(status_code=409, detail=sess.error or sess.status)
    try:
        return get_step(sess, n)
    except IndexError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc


@app.get("/api/sessions/{sid}/steps")
def api_get_steps(
    sid: str,
    start: int = Query(0, alias="from"),
    to: int | None = None,
) -> dict[str, Any]:
    sess = session_get(sid)
    if sess is None:
        raise HTTPException(status_code=404, detail="session not found")
    if sess.status != "ready":
        raise HTTPException(status_code=409, detail=sess.error or sess.status)
    end = to if to is not None else len(sess.steps)
    end = min(end, len(sess.steps))
    begin = max(0, start)
    return {"from": begin, "to": end, "steps": sess.steps[begin:end]}


@app.get("/api/sessions/{sid}/events")
def api_get_events(sid: str) -> dict[str, Any]:
    sess = session_get(sid)
    if sess is None:
        raise HTTPException(status_code=404, detail="session not found")
    return {"events": sess.events}


@app.get("/api/sessions/{sid}/disasm")
def api_get_disasm(sid: str) -> dict[str, Any]:
    sess = session_get(sid)
    if sess is None:
        raise HTTPException(status_code=404, detail="session not found")
    return {"disasm": sess.disasm}


@app.get("/api/sessions/{sid}/heap/{addr}")
def api_get_heap(sid: str, addr: str, step: int | None = None) -> dict[str, Any]:
    sess = session_get(sid)
    if sess is None:
        raise HTTPException(status_code=404, detail="session not found")
    if sess.status != "ready":
        raise HTTPException(status_code=409, detail=sess.error or sess.status)
    try:
        a = int(addr, 0)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail="bad address") from exc
    try:
        return get_heap(sess, a, step)
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status_code=400, detail=str(exc)) from exc


# Static frontend (production build).
if STATIC_DIR.is_dir():
    app.mount("/assets", StaticFiles(directory=STATIC_DIR / "assets"), name="assets")

    @app.get("/")
    def index() -> FileResponse:
        return FileResponse(STATIC_DIR / "index.html")

    @app.get("/{path:path}")
    def spa_fallback(path: str) -> FileResponse:
        candidate = STATIC_DIR / path
        if candidate.is_file():
            return FileResponse(candidate)
        return FileResponse(STATIC_DIR / "index.html")


def main() -> None:
    import uvicorn

    host = os.environ.get("SIM_UI_HOST", "0.0.0.0")
    port = int(os.environ.get("SIM_UI_PORT", "8000"))
    uvicorn.run("sim_ui.server.app:app", host=host, port=port, reload=False)


if __name__ == "__main__":
    main()
