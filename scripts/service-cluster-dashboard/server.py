# VersionTag: 2605.B5.V46.0
# FileRole: ServiceDashboard-Backend
# service-cluster-dashboard/server.py
# FastAPI backend for PwShGUI Service Cluster Dashboard
# Serves metrics, cluster control, job queues, MCP status, agent pipeline status
# Loopback + trusted-cluster REST interop. SSE for realtime push.
"""
PwShGUI Service Cluster Dashboard — FastAPI backend
Port: 8099 (default)
Auth: node-shared HMAC token header  X-Cluster-Token
"""

from __future__ import annotations

import asyncio
import html
import hashlib
import hmac
import json
import logging
import os
import platform
import re
import secrets
import subprocess
import sys
import time
from collections import deque
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

import httpx
import psutil
import uvicorn
from fastapi import (
    Depends,
    FastAPI,
    Header,
    HTTPException,
    Query,
    Request,
    WebSocket,
    WebSocketDisconnect,
)
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

# ── Paths ─────────────────────────────────────────────────────────────────────

SCRIPT_DIR   = Path(__file__).resolve().parent
WORKSPACE    = SCRIPT_DIR.parent.parent          # C:\PowerShellGUI
LOGS_DIR     = WORKSPACE / "logs"
ENGINE_LOG   = LOGS_DIR / "engine-stdout.log"
SERVICE_LOG  = LOGS_DIR / "engine-service.log"
MCP_CFG_FILE = WORKSPACE / ".vscode" / "mcp.json"
CONFIG_DIR   = WORKSPACE / "config"
MODULES_DIR  = WORKSPACE / "modules"
AGENTS_DIR   = WORKSPACE / "agents"
SCRIPTS_DIR  = WORKSPACE / "scripts"
SIN_DIR      = WORKSPACE / "sin_registry"
STATIC_DIR   = SCRIPT_DIR / "static"

ENGINE_INSTANCE_FILE = LOGS_DIR / "engine-instance-current.json"
ENGINE_PID_FILE      = LOGS_DIR / "engine.pid"
ENGINE_PORT          = 8042    # local PS web engine port

# ── Config ────────────────────────────────────────────────────────────────────

DASHBOARD_PORT    = int(os.environ.get("DASHBOARD_PORT", 8099))
CLUSTER_TOKEN_ENV = "PWSHGUI_CLUSTER_TOKEN"
CLUSTER_TOKEN     = os.environ.get(CLUSTER_TOKEN_ENV) or secrets.token_hex(32)

if CLUSTER_TOKEN_ENV not in os.environ:
    token_file = SCRIPT_DIR / "cluster.token"
    if token_file.exists():
        CLUSTER_TOKEN = token_file.read_text(encoding="utf-8").strip()
    else:
        token_file.write_text(CLUSTER_TOKEN, encoding="utf-8")

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("dashboard")

# ── Job Queue ─────────────────────────────────────────────────────────────────

_job_queue: deque[Dict[str, Any]] = deque(maxlen=200)
_job_results: Dict[str, Any] = {}
_job_lock = asyncio.Lock()

# ── WebSocket connections ─────────────────────────────────────────────────────

_ws_clients: List[WebSocket] = []
_ws_lock = asyncio.Lock()

# ── Cluster registry  (this node + known peers) ──────────────────────────────

_cluster_nodes: Dict[str, Dict[str, Any]] = {}
_cluster_lock = asyncio.Lock()

THIS_NODE = {
    "id": platform.node(),
    "host": "127.0.0.1",
    "port": DASHBOARD_PORT,
    "role": os.environ.get("CLUSTER_ROLE", "MASTER"),   # MASTER | CLONE
    "version": "2604.B2.V31.0",
}

# ── Metric snapshots ─────────────────────────────────────────────────────────

_metrics_cache: Dict[str, Any] = {}
_metrics_ts: float = 0.0

# ─────────────────────────────────────────────────────────────────────────────
# Auth helpers
# ─────────────────────────────────────────────────────────────────────────────

def _verify_token(x_cluster_token: str = Header(default="")) -> None:
    """HMAC constant-time compare against the shared cluster token."""
    if not hmac.compare_digest(x_cluster_token, CLUSTER_TOKEN):
        raise HTTPException(status_code=401, detail="Invalid cluster token")


def _optional_token(x_cluster_token: str = Header(default="")) -> bool:
    """Returns True if token is valid (non-raising, for hybrid public/auth endpoints)."""
    return hmac.compare_digest(x_cluster_token, CLUSTER_TOKEN)


# ─────────────────────────────────────────────────────────────────────────────
# Utility helpers
# ─────────────────────────────────────────────────────────────────────────────

def _read_json_safe(path: Path) -> Optional[Any]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None


def _tail_log(path: Path, n: int = 200) -> List[str]:
    if not path.exists():
        return []
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        return lines[-n:]
    except Exception:
        return []


def _get_engine_pid() -> Optional[int]:
    try:
        return int(ENGINE_PID_FILE.read_text(encoding="utf-8").strip())
    except Exception:
        return None


def _engine_running() -> bool:
    pid = _get_engine_pid()
    if pid is None:
        return False
    try:
        return psutil.pid_exists(pid) and psutil.Process(pid).is_running()
    except Exception:
        return False


async def _engine_responding() -> bool:
    try:
        async with httpx.AsyncClient(timeout=2.0) as client:
            r = await client.get(f"http://127.0.0.1:{ENGINE_PORT}/api/engine/status")
            return r.status_code < 500
    except Exception:
        return False


def _collect_metrics() -> Dict[str, Any]:
    cpu = psutil.cpu_percent(interval=None)
    vm  = psutil.virtual_memory()
    boot_ts = datetime.fromtimestamp(psutil.boot_time(), tz=timezone.utc).isoformat()
    try:
        disk = psutil.disk_usage(str(WORKSPACE))
        disk_info = {
            "total_gb": round(disk.total / 1e9, 2),
            "used_gb":  round(disk.used  / 1e9, 2),
            "free_gb":  round(disk.free  / 1e9, 2),
            "percent":  disk.percent,
        }
    except Exception:
        disk_info = {}
    proc_list = []
    # NOTE: 'memory_mb' is NOT a valid psutil attr name — it raises
    # "invalid attr name 'memory_mb'" in process_iter(). We compute it
    # ourselves from memory_info().rss below.
    for proc in psutil.process_iter(["pid", "name", "cpu_percent", "status"]):
        try:
            pi = proc.info
            try:
                pi["memory_mb"] = round(proc.memory_info().rss / 1e6, 1)
            except Exception:
                pi["memory_mb"] = 0
            proc_list.append(pi)
        except Exception:
            pass
    proc_list.sort(key=lambda p: p.get("cpu_percent", 0), reverse=True)

    return {
        "ts":      datetime.now(tz=timezone.utc).isoformat(),
        "cpu_pct": cpu,
        "ram": {
            "total_gb":     round(vm.total   / 1e9, 2),
            "available_gb": round(vm.available / 1e9, 2),
            "used_pct":     vm.percent,
        },
        "disk": disk_info,
        "boot_time": boot_ts,
        "top_procs": proc_list[:20],
    }


def _list_mcp_servers() -> List[Dict[str, Any]]:
    cfg = _read_json_safe(MCP_CFG_FILE)
    if not cfg or "servers" not in cfg:
        return []
    result = []
    for name, defn in cfg["servers"].items():
        result.append({
            "name":   name,
            "type":   defn.get("type", "stdio"),
            "status": "configured",
        })
    return result


def _list_agents() -> List[Dict[str, Any]]:
    items = []
    for p in sorted(AGENTS_DIR.rglob("*.py")):
        if p.name.startswith("_"):
            continue
        rel = str(p.relative_to(WORKSPACE))
        items.append({"file": rel, "name": p.stem})
    return items


def _list_pipeline_tasks() -> List[Dict[str, Any]]:
    pipe_file = CONFIG_DIR / "cron-aiathon-pipeline.json"
    data = _read_json_safe(pipe_file)
    if not data:
        return []
    tasks = []
    for cat in ("bugs", "featureRequests", "items2ADD", "bugs2FIX", "todos"):
        for item in data.get(cat, []):
            tasks.append({
                "category": cat,
                "id":       item.get("id", ""),
                "title":    item.get("title") or item.get("name", ""),
                "status":   item.get("status", ""),
                "priority": item.get("priority", ""),
            })
    return tasks


def _list_admin_tools() -> List[Dict[str, Any]]:
    tools = []
    for ps in sorted(SCRIPTS_DIR.glob("Show-*.ps1")):
        tools.append({"name": ps.stem, "path": str(ps.relative_to(WORKSPACE)), "type": "show"})
    for ps in sorted(SCRIPTS_DIR.glob("Invoke-*.ps1")):
        tools.append({"name": ps.stem, "path": str(ps.relative_to(WORKSPACE)), "type": "invoke"})
    return tools


def _sin_summary() -> Dict[str, Any]:
    total = critical = medium = high = resolved = penance = 0
    try:
        for f in SIN_DIR.glob("*.json"):
            d = _read_json_safe(f)
            if not d:
                continue
            total += 1
            sev = (d.get("severity") or "").upper()
            if sev == "CRITICAL":
                critical += 1
            elif sev == "HIGH":
                high += 1
            elif sev in ("MEDIUM","LOW"):
                medium += 1
            elif sev == "PENANCE":
                penance += 1
            if d.get("is_resolved"):
                resolved += 1
    except Exception:
        pass
    return {
        "total": total,
        "critical": critical,
        "high": high,
        "medium": medium,
        "penance": penance,
        "resolved": resolved,
    }


# ─────────────────────────────────────────────────────────────────────────────
# Background tasks
# ─────────────────────────────────────────────────────────────────────────────

async def _broadcast_metrics_loop() -> None:
    """Push a metrics snapshot to all WebSocket clients every 3 s."""
    global _metrics_cache, _metrics_ts
    while True:
        await asyncio.sleep(3)
        try:
            snap = _collect_metrics()
            snap["engine_running"]  = _engine_running()
            snap["engine_pid"]      = _get_engine_pid()
            _metrics_cache = snap
            _metrics_ts    = time.monotonic()
            payload = json.dumps({"type": "metrics", "data": snap})
            async with _ws_lock:
                dead = []
                for ws in list(_ws_clients):
                    try:
                        await ws.send_text(payload)
                    except Exception:
                        dead.append(ws)
                for d in dead:
                    _ws_clients.remove(d)
        except Exception as exc:
            log.warning("metrics broadcast error: %s", exc)


async def _heartbeat_peers_loop() -> None:
    """Send heartbeat POST to each registered peer every 15 s."""
    while True:
        await asyncio.sleep(15)
        async with _cluster_lock:
            peers = list(_cluster_nodes.values())
        for peer in peers:
            if peer.get("host") == THIS_NODE["host"] and peer.get("port") == THIS_NODE["port"]:
                continue
            try:
                url = f"http://{peer['host']}:{peer['port']}/api/cluster/heartbeat"
                async with httpx.AsyncClient(timeout=3.0) as client:
                    await client.post(
                        url,
                        json=THIS_NODE,
                        headers={"X-Cluster-Token": CLUSTER_TOKEN},
                    )
            except Exception:
                pass


@asynccontextmanager
async def _lifespan(app: FastAPI):
    asyncio.create_task(_broadcast_metrics_loop())
    asyncio.create_task(_heartbeat_peers_loop())
    yield


# ─────────────────────────────────────────────────────────────────────────────
# App
# ─────────────────────────────────────────────────────────────────────────────

app = FastAPI(
    title="PwShGUI Service Cluster Dashboard",
    version="2604.B2.V31.0",
    lifespan=_lifespan,
    docs_url="/api/docs",
    redoc_url="/api/redoc",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://127.0.0.1:8099", "http://localhost:8099", "null"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Serve static SPA
if STATIC_DIR.exists():
    app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")


# ─────────────────────────────────────────────────────────────────────────────
# Pydantic models
# ─────────────────────────────────────────────────────────────────────────────

class JobSubmit(BaseModel):
    tool: str
    params: Dict[str, Any] = Field(default_factory=dict)
    label: str = ""


class ClusterNodeInfo(BaseModel):
    id: str
    host: str
    port: int
    role: str = "CLONE"
    version: str = ""


class ClusterAction(BaseModel):
    action: str   # promote | demote | remove | restart
    target_id: str


class EngineAction(BaseModel):
    action: str   # start | stop | restart


# ─────────────────────────────────────────────────────────────────────────────
# Routes — public/lightweight
# ─────────────────────────────────────────────────────────────────────────────

@app.get("/", response_class=HTMLResponse, tags=["UI"])
async def root():
    index = STATIC_DIR / "index.html"
    if index.exists():
        content = index.read_text(encoding="utf-8")
        # Inject runtime cluster token so local dashboard can authenticate on
        # first load and recover from stale browser cache tokens.
        content = content.replace("__CLUSTER_TOKEN__", html.escape(CLUSTER_TOKEN, quote=True))
        return HTMLResponse(content=content)
    return HTMLResponse("<p>Static files not found. Check static/index.html.</p>")


# ─── Root-level passthroughs for page-relative asset references ──────────────
# index.html references 'style.css' and 'app.js' as page-relative URLs, which
# the browser resolves to '/style.css' and '/app.js'. Serve these (plus the
# common implicit /favicon.ico and /robots.txt requests) from /static so the
# page renders without 404 chatter in the access log.
from fastapi.responses import FileResponse, Response

@app.get("/style.css", include_in_schema=False)
async def _root_stylecss():
    f = STATIC_DIR / "style.css"
    if f.exists():
        return FileResponse(str(f), media_type="text/css")
    return Response(status_code=404)

@app.get("/app.js", include_in_schema=False)
async def _root_appjs():
    f = STATIC_DIR / "app.js"
    if f.exists():
        return FileResponse(str(f), media_type="application/javascript")
    return Response(status_code=404)

@app.get("/favicon.ico", include_in_schema=False)
async def _root_favicon():
    f = STATIC_DIR / "favicon.ico"
    if f.exists():
        return FileResponse(str(f), media_type="image/x-icon")
    # 1x1 transparent ICO — silences browser auto-request
    return Response(
        content=(
            b"\x00\x00\x01\x00\x01\x00\x01\x01\x00\x00\x01\x00\x18\x00\x30\x00"
            b"\x00\x00\x16\x00\x00\x00\x28\x00\x00\x00\x01\x00\x00\x00\x02\x00"
            b"\x00\x00\x01\x00\x18\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
            b"\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
            b"\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
        ),
        media_type="image/x-icon",
    )

@app.get("/robots.txt", include_in_schema=False)
async def _root_robots():
    return Response(content="User-agent: *\nDisallow: /\n", media_type="text/plain")

@app.get("/api/ping", tags=["Health"])
async def ping():
    return {"status": "ok", "ts": datetime.now(tz=timezone.utc).isoformat(), "node": THIS_NODE["id"]}


@app.get("/api/node/info", tags=["Cluster"])
async def node_info():
    return THIS_NODE


# ─────────────────────────────────────────────────────────────────────────────
# Routes — metrics
# ─────────────────────────────────────────────────────────────────────────────

@app.get("/api/metrics", tags=["Metrics"])
async def metrics(_=Depends(_verify_token)):
    snap = _collect_metrics()
    snap["engine_running"] = _engine_running()
    snap["engine_pid"]     = _get_engine_pid()
    snap["engine_responding"] = await _engine_responding()
    return snap


@app.get("/api/metrics/lite", tags=["Metrics"])
async def metrics_lite():
    """Fast cached snapshot — no token required (no sensitive data)."""
    global _metrics_cache, _metrics_ts
    if time.monotonic() - _metrics_ts > 5:
        _metrics_cache = _collect_metrics()
        _metrics_cache["engine_running"] = _engine_running()
        _metrics_ts = time.monotonic()
    return _metrics_cache


# ─────────────────────────────────────────────────────────────────────────────
# Routes — engine
# ─────────────────────────────────────────────────────────────────────────────

@app.get("/api/engine/status", tags=["Engine"])
async def engine_status(_=Depends(_verify_token)):
    state = _read_json_safe(ENGINE_INSTANCE_FILE) or {}
    return {
        "running":    _engine_running(),
        "responding": await _engine_responding(),
        "pid":        _get_engine_pid(),
        "port":       ENGINE_PORT,
        "instance":   state,
    }


@app.get("/api/engine/log", tags=["Engine"])
async def engine_log(name: str = Query("stdout"), lines: int = Query(200), _=Depends(_verify_token)):
    log_map = {
        "stdout":  ENGINE_LOG,
        "service": SERVICE_LOG,
        "crash":   LOGS_DIR / "engine-crash.log",
        "boot":    LOGS_DIR / "engine-bootstrap.log",
    }
    path = log_map.get(name, ENGINE_LOG)
    return {"name": name, "lines": _tail_log(path, lines)}


@app.post("/api/engine/control", tags=["Engine"])
async def engine_control(body: EngineAction, _=Depends(_verify_token)):
    """Start / stop / restart the PowerShell Local Web Engine."""
    action = body.action.lower()
    if action not in ("start", "stop", "restart"):
        raise HTTPException(400, "action must be start|stop|restart")

    # Stop/restart should use the engine API so control flows through the primary script.
    if action in ("stop", "restart") and await _engine_responding():
        try:
            async with httpx.AsyncClient(timeout=3.0) as client:
                tok_resp = await client.get(f"http://127.0.0.1:{ENGINE_PORT}/api/csrf-token")
                tok_resp.raise_for_status()
                csrf_token = tok_resp.json().get("csrfToken", "")
                if not csrf_token:
                    raise HTTPException(500, "Engine csrfToken was empty")
                stop_resp = await client.post(
                    f"http://127.0.0.1:{ENGINE_PORT}/api/engine/stop",
                    headers={"X-CSRF-Token": csrf_token},
                )
                stop_resp.raise_for_status()
        except HTTPException:
            raise
        except Exception as exc:
            raise HTTPException(500, f"Engine stop failed: {exc}")

    if action == "stop":
        return {"submitted": True, "action": action, "mode": "api"}

    engine_script = SCRIPTS_DIR / "Start-LocalWebEngine.ps1"
    if not engine_script.exists():
        raise HTTPException(500, "Start-LocalWebEngine.ps1 not found")

    ps_action = "Start"
    cmd = ["powershell.exe", "-NonInteractive", "-NoProfile",
           "-ExecutionPolicy", "Bypass",
           "-File", str(engine_script),
           "-Action", ps_action,
           "-NoLaunchBrowser"]
    try:
        proc = subprocess.Popen(cmd, cwd=str(WORKSPACE))
        return {"submitted": True, "pid": proc.pid, "action": action}
    except Exception as exc:
        raise HTTPException(500, str(exc))


# ─────────────────────────────────────────────────────────────────────────────
# Routes — MCP
# ─────────────────────────────────────────────────────────────────────────────

@app.get("/api/mcp/servers", tags=["MCP"])
async def mcp_servers(_=Depends(_verify_token)):
    servers = _list_mcp_servers()
    # Enrich: proxy a status check to the running engine if available
    if await _engine_responding():
        try:
            async with httpx.AsyncClient(timeout=3.0) as client:
                r = await client.get(f"http://127.0.0.1:{ENGINE_PORT}/api/engine/status")
                engine_data = r.json()
            for s in servers:
                s["engine_reported"] = True
        except Exception:
            pass
    return {"servers": servers, "count": len(servers)}


# ─────────────────────────────────────────────────────────────────────────────
# Routes — Agents & Pipeline
# ─────────────────────────────────────────────────────────────────────────────

@app.get("/api/agents", tags=["Agents"])
async def agents(_=Depends(_verify_token)):
    return {"agents": _list_agents()}


@app.get("/api/pipeline/tasks", tags=["Pipeline"])
async def pipeline_tasks(_=Depends(_verify_token)):
    return {"tasks": _list_pipeline_tasks()}


@app.get("/api/tools/admin", tags=["Tools"])
async def admin_tools(_=Depends(_verify_token)):
    return {"tools": _list_admin_tools()}


@app.post("/api/tools/launch", tags=["Tools"])
async def launch_tool(body: JobSubmit, _=Depends(_verify_token)):
    """Launch a script tool by name (Show-*.ps1 / Invoke-*.ps1)."""
    # Validate name — no path chars allowed (P009)
    if re.search(r'[/\\\.]{2}|[<>|;&`]', body.tool):
        raise HTTPException(400, "Invalid tool name")
    ps1 = SCRIPTS_DIR / f"{body.tool}.ps1"
    if not ps1.exists():
        raise HTTPException(404, f"Tool script not found: {body.tool}.ps1")
    cmd = ["powershell.exe", "-NonInteractive", "-NoProfile",
           "-ExecutionPolicy", "Bypass",
           "-File", str(ps1)]
    try:
        proc = subprocess.Popen(cmd, cwd=str(WORKSPACE))
        return {"launched": True, "pid": proc.pid, "tool": body.tool}
    except Exception as exc:
        raise HTTPException(500, str(exc))


# ─────────────────────────────────────────────────────────────────────────────
# Routes — Job Queue
# ─────────────────────────────────────────────────────────────────────────────

@app.get("/api/jobs", tags=["Jobs"])
async def list_jobs(_=Depends(_verify_token)):
    return {"jobs": list(_job_queue), "count": len(_job_queue)}


@app.post("/api/jobs", tags=["Jobs"])
async def submit_job(body: JobSubmit, _=Depends(_verify_token)):
    job_id = secrets.token_hex(8)
    job = {
        "id":        job_id,
        "tool":      body.tool,
        "params":    body.params,
        "label":     body.label or body.tool,
        "status":    "queued",
        "submitted": datetime.now(tz=timezone.utc).isoformat(),
        "result":    None,
    }
    async with _job_lock:
        _job_queue.appendleft(job)
    return {"job_id": job_id, "status": "queued"}


@app.get("/api/jobs/{job_id}", tags=["Jobs"])
async def get_job(job_id: str, _=Depends(_verify_token)):
    for j in _job_queue:
        if j["id"] == job_id:
            return j
    raise HTTPException(404, "Job not found")


# ─────────────────────────────────────────────────────────────────────────────
# Routes — Cluster
# ─────────────────────────────────────────────────────────────────────────────

@app.get("/api/cluster/nodes", tags=["Cluster"])
async def cluster_nodes(_=Depends(_verify_token)):
    async with _cluster_lock:
        nodes = [THIS_NODE] + [n for n in _cluster_nodes.values()
                               if n.get("id") != THIS_NODE["id"]]
    return {"nodes": nodes, "master": THIS_NODE["id"] if THIS_NODE["role"] == "MASTER" else None}


@app.post("/api/cluster/register", tags=["Cluster"])
async def cluster_register(body: ClusterNodeInfo, _=Depends(_verify_token)):
    async with _cluster_lock:
        _cluster_nodes[body.id] = body.model_dump()
    return {"registered": True, "id": body.id}


@app.post("/api/cluster/heartbeat", tags=["Cluster"])
async def cluster_heartbeat(body: Dict[str, Any], _=Depends(_verify_token)):
    node_id = body.get("id", "unknown")
    body["last_seen"] = datetime.now(tz=timezone.utc).isoformat()
    async with _cluster_lock:
        _cluster_nodes[node_id] = body
    return {"ack": True}


@app.post("/api/cluster/control", tags=["Cluster"])
async def cluster_control(body: ClusterAction, _=Depends(_verify_token)):
    """Master-only: promote/demote/remove/restart a cluster node."""
    if THIS_NODE["role"] != "MASTER":
        raise HTTPException(403, "Only the MASTER node may issue cluster control commands")
    async with _cluster_lock:
        target = _cluster_nodes.get(body.target_id)
    if not target:
        raise HTTPException(404, "Node not found")
    action = body.action.lower()
    if action == "remove":
        async with _cluster_lock:
            _cluster_nodes.pop(body.target_id, None)
        return {"removed": body.target_id}
    # Forward action to the target node
    try:
        url = f"http://{target['host']}:{target['port']}/api/node/action"
        async with httpx.AsyncClient(timeout=5.0) as client:
            r = await client.post(
                url,
                json={"action": action},
                headers={"X-Cluster-Token": CLUSTER_TOKEN},
            )
        return r.json()
    except Exception as exc:
        raise HTTPException(502, f"Could not reach node: {exc}")


@app.post("/api/node/action", tags=["Cluster"])
async def node_action(body: Dict[str, Any], _=Depends(_verify_token)):
    """Accept control commands forwarded from the MASTER node."""
    action = (body.get("action") or "").lower()
    if action == "promote":
        THIS_NODE["role"] = "MASTER"
    elif action == "demote":
        THIS_NODE["role"] = "CLONE"
    elif action == "restart":
        # Restart this Python process gracefully
        asyncio.get_event_loop().call_later(2, lambda: os.execv(sys.executable, [sys.executable] + sys.argv))
    return {"ack": True, "action": action, "node": THIS_NODE["id"]}


# ─────────────────────────────────────────────────────────────────────────────
# Routes — Security & SIN
# ─────────────────────────────────────────────────────────────────────────────

@app.get("/api/security/sins", tags=["Security"])
async def sin_summary_route(_=Depends(_verify_token)):
    return _sin_summary()


@app.get("/api/security/sins/detail", tags=["Security"])
async def sin_detail(_=Depends(_verify_token)):
    records = []
    for f in sorted(SIN_DIR.glob("*.json")):
        d = _read_json_safe(f)
        if d:
            records.append(d)
    return {"sins": records, "count": len(records)}


# ─────────────────────────────────────────────────────────────────────────────
# Routes — MainGUI menu mirror
# ─────────────────────────────────────────────────────────────────────────────

@app.get("/api/menu/maingui", tags=["Menu"])
async def maingui_menu():
    """
    Returns a structured representation of the MainGUI menu tree.
    Mirrors the same items accessible via the tray icon and task bar.
    Used by the SPA to render the linked sub-interface panel.
    """
    return {
        "menu": [
            {
                "label": "File",
                "items": [
                    {"label": "Settings — Path Configuration", "action": "launch", "tool": "Show-PathSettings"},
                    {"label": "Settings — Script Folders",     "action": "launch", "tool": "Show-ScriptFolders"},
                    {"label": "Exit",                          "action": "system", "tool": "exit"},
                ]
            },
            {
                "label": "Tests",
                "items": [
                    {"label": "Version Check",        "action": "launch", "tool": "Test-VersionTag"},
                    {"label": "Network Diagnostics",  "action": "launch", "tool": "Show-NetworkDiagnostics"},
                    {"label": "Disk Check",            "action": "launch", "tool": "Show-DiskCheck"},
                    {"label": "Privacy Check",         "action": "launch", "tool": "Show-PrivacyCheck"},
                    {"label": "System Check",          "action": "launch", "tool": "Show-SystemCheck"},
                ]
            },
            {
                "label": "Links",
                "items": [
                    {"label": "CORPORATE",   "action": "links_category", "category": "CORPORATE"},
                    {"label": "PUBLIC-INFO", "action": "links_category", "category": "PUBLIC-INFO"},
                    {"label": "LOCAL",       "action": "links_category", "category": "LOCAL"},
                    {"label": "M365",        "action": "links_category", "category": "M365"},
                    {"label": "SEARCH",      "action": "links_category", "category": "SEARCH"},
                    {"label": "USERS-URLS",  "action": "links_category", "category": "USERS-URLS"},
                ]
            },
            {
                "label": "WinGets",
                "items": [
                    {"label": "Installed Apps (Grid)",    "action": "launch", "tool": "Show-WingetInstalledApp"},
                    {"label": "Detect Updates",           "action": "launch", "tool": "Show-WingetUpgradeCheck"},
                    {"label": "Update All (Admin)",       "action": "launch", "tool": "Show-WingetUpdateAll"},
                ]
            },
            {
                "label": "Tools",
                "items": [
                    {"label": "View Config",                "action": "launch", "tool": "View-Config"},
                    {"label": "Open Logs Directory",        "action": "open_folder", "path": "logs"},
                    {"label": "Button Maintenance",         "action": "launch", "tool": "Show-ButtonMaintenance"},
                    {"label": "Network Details",            "action": "launch", "tool": "Show-NetworkDetails"},
                    {"label": "AVPN Connection Tracker",    "action": "launch", "tool": "Show-AVPNTracker"},
                    {"label": "Cron-Ai-Athon Tool",         "action": "launch", "tool": "Show-CronAiAthonTool"},
                    {"label": "MCP Service Config",         "action": "launch", "tool": "Show-MCPServiceConfig"},
                    {"label": "Certificate Manager",        "action": "launch", "tool": "Show-CertificateManager"},
                    {"label": "Event Log Viewer",           "action": "launch", "tool": "Show-EventLogViewer"},
                    {"label": "Scan Dashboard",             "action": "launch", "tool": "Show-ScanDashboard"},
                    {"label": "Workspace Intent Review",    "action": "launch", "tool": "Show-WorkspaceIntentReview"},
                ]
            },
            {
                "label": "Help",
                "items": [
                    {"label": "Update Help",             "action": "launch", "tool": "Update-Help"},
                    {"label": "Package Workspace",       "action": "launch", "tool": "Build-Package"},
                    {"label": "Manifests & SINs Viewer", "action": "launch", "tool": "Show-ManifestsSINs"},
                    {"label": "About",                   "action": "launch", "tool": "Show-About"},
                ]
            },
        ]
    }


# ─────────────────────────────────────────────────────────────────────────────
# WebSocket — realtime events
# ─────────────────────────────────────────────────────────────────────────────

@app.websocket("/ws/metrics")
async def ws_metrics(websocket: WebSocket):
    # Simple token check via query param for WS (headers not reliable in browsers)
    token = websocket.query_params.get("token", "")
    if not hmac.compare_digest(token, CLUSTER_TOKEN):
        await websocket.close(code=1008)
        return
    await websocket.accept()
    async with _ws_lock:
        _ws_clients.append(websocket)
    try:
        # Send initial snapshot immediately
        snap = _collect_metrics()
        snap["engine_running"] = _engine_running()
        await websocket.send_text(json.dumps({"type": "metrics", "data": snap}))
        while True:
            try:
                msg = await asyncio.wait_for(websocket.receive_text(), timeout=30)
                # Echo pings
                if msg == "ping":
                    await websocket.send_text(json.dumps({"type": "pong"}))
            except asyncio.TimeoutError:
                await websocket.send_text(json.dumps({"type": "keepalive"}))
    except WebSocketDisconnect:
        pass
    finally:
        async with _ws_lock:
            if websocket in _ws_clients:
                _ws_clients.remove(websocket)


# ─────────────────────────────────────────────────────────────────────────────
# Entry point
# ─────────────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    print(f"[INFO] PwShGUI Service Cluster Dashboard starting on http://127.0.0.1:{DASHBOARD_PORT}")
    print(f"[INFO] Cluster role: {THIS_NODE['role']}")
    print(f"[INFO] Cluster token file: {SCRIPT_DIR / 'cluster.token'}")
    uvicorn.run(
        "server:app",
        host="127.0.0.1",
        port=DASHBOARD_PORT,
        reload=False,
        log_level="info",
        ws="websockets",
    )

