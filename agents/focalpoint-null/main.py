# VersionTag: 2604.B2.V31.0
# VersionTag: 2604.B2.V31.0
# VersionTag: 2604.B2.V31.0
# VersionTag: 2604.B2.V31.0
"""
FocalPoint-null Main Entry Point
HTTP server mode (default) with debug + AI Toolkit Agent Inspector support.
CLI mode available with --cli flag.
"""
from __future__ import annotations

import argparse
import asyncio
import html
import json
import os
import sys
import time
import webbrowser
from pathlib import Path
from urllib.parse import quote, urlparse

from dotenv import load_dotenv

# Load .env with override=True for deployed environments
load_dotenv(override=True)

# MUST apply compatibility patches BEFORE importing agent_framework
from compat import apply_patches
apply_patches()

from agent_framework import (
    ChatMessage,
    WorkflowBuilder,
)
from agent_framework.exceptions import ServiceResponseException
from agent_framework.openai import OpenAIChatClient
# AzureAIClient requires azure-ai-projects with PromptAgentDefinitionText — import conditionally
try:
    from agent_framework.azure import AzureAIClient as _AzureAIClient
except ImportError:
    _AzureAIClient = None  # type: ignore
try:
    from azure.identity.aio import DefaultAzureCredential as _DefaultAzureCredential
except ImportError:
    _DefaultAzureCredential = None  # type: ignore

from agents.focalpoint_orchestrator import FocalPointOrchestrator
from agents.sub_agents import (
    AgentReviewExecutor,
    QualityControlExecutor,
    SecurityTriageExecutor,
    StandardsGuardExecutor,
)
from agents.code_compiler_agent import CodeCompilerExecutor
from agents.code_tester_agent import CodeTesterExecutor
from core.checkpoint_manager import CheckpointManager
from core.consensus_engine import ConsensusEngine
from core.log_manager import LogManager, LogLevel
from core.monitoring import RuntimeMonitor
from core.multi_model_dispatcher import MultiModelDispatcher
from core.pki_manager import PKIManager
from core.sin_registry import SinRegistry
from core.viewpoint_init import ViewPointInit


# ─────────────────────────────────────────────
# ENVIRONMENT & SETTINGS
# ─────────────────────────────────────────────

def get_settings() -> dict:
    return {
        "github_token": os.getenv("GITHUB_TOKEN", ""),
        "github_endpoint": os.getenv("GITHUB_MODEL_ENDPOINT", "https://models.inference.ai.azure.com"),
        "foundry_endpoint": os.getenv("FOUNDRY_PROJECT_ENDPOINT", ""),
        "orchestrator_model": os.getenv("ORCHESTRATOR_MODEL", "openai/gpt-4.1"),
        "subagent_model": os.getenv("SUBAGENT_MODEL", "openai/gpt-4.1-mini"),
        "review_model": os.getenv("REVIEW_MODEL", "openai/gpt-4.1"),
        "pki_dir": os.getenv("PKI_DIR", "pki"),
        "checkpoint_dir": os.getenv("CHECKPOINT_DIR", "checkpoints"),
        "log_dir": os.getenv("LOG_DIR", "logs"),
        "todo_dir": os.getenv("TODO_DIR", "todo"),
        "allow_organic_growth": os.getenv("ALLOW_AUTONOMOUS_ORGANIC_GROWTH", "false").lower() == "true",
        "sin_registry_dir": os.getenv("SIN_REGISTRY_DIR", "sin_registry"),
        "modules_dir": os.getenv("MODULES_DIR", "modules"),
        "scripts_dir": os.getenv("SCRIPTS_DIR", "scripts"),
        "http_host": os.getenv("HTTP_HOST", "0.0.0.0"),
        "http_port": int(os.getenv("HTTP_PORT", "8087")),
        "dashboard_host": os.getenv("DASHBOARD_HOST", "127.0.0.1"),
        "dashboard_port": int(os.getenv("DASHBOARD_PORT", "8888")),
        "dashboard_auto_open": os.getenv("DASHBOARD_AUTO_OPEN", "true").lower() == "true",
        # Multi-model parallel dispatch settings
        "multi_model_enabled": os.getenv("MULTI_MODEL_ENABLED", "false").lower() == "true",
        "multi_model_failover_threshold": float(os.getenv("MULTI_MODEL_FAILOVER_THRESHOLD", "0.35")),
        "multi_model_timeout": float(os.getenv("MULTI_MODEL_TIMEOUT_SECONDS", "30")),
    }


def _normalize_github_model_name(model_name: str) -> str:
    if not model_name:
        return model_name
    if "/" in model_name:
        return model_name.split("/", 1)[1]
    return model_name


# ─────────────────────────────────────────────
# CLIENT FACTORY
# ─────────────────────────────────────────────

def create_client(settings: dict, model_override: str | None = None):
    """
    Create a client. Prefers Foundry if configured, falls back to GitHub Models.
    Returns AzureAIClient (Foundry) or OpenAIChatClient (GitHub Models).
    """
    model = model_override or settings["orchestrator_model"]
    foundry_endpoint = settings.get("foundry_endpoint", "")
    github_token = settings.get("github_token", "")

    if foundry_endpoint:
        # Use Microsoft Foundry with default Azure credential
        if _AzureAIClient is None or _DefaultAzureCredential is None:
            raise RuntimeError(
                "AzureAIClient not available — azure-ai-projects is missing PromptAgentDefinitionText. "
                "Configure GITHUB_TOKEN instead, or upgrade azure-ai-projects."
            )
        credential = _DefaultAzureCredential()
        return _AzureAIClient(
            endpoint=foundry_endpoint,
            credential=credential,
            model=model,
        )
    elif github_token:
        # Use GitHub Models via OpenAI-compatible endpoint
        # OpenAIChatClient uses base_url + api_key + model_id
        from openai import AsyncOpenAI
        github_model = _normalize_github_model_name(model)
        async_client = AsyncOpenAI(
            base_url=settings["github_endpoint"],
            api_key=github_token,
        )
        return OpenAIChatClient(
            model_id=github_model,
            async_client=async_client,
        )
    else:
        raise RuntimeError(
            "No model credentials configured. "
            "Set GITHUB_TOKEN (for GitHub Models) or FOUNDRY_PROJECT_ENDPOINT + Azure credential."
        )


def _auth_help_message(error: Exception, settings: dict) -> str:
    message = str(error)
    if "unknown_model" in message.lower() or "unknown model" in message.lower():
        configured = settings.get("orchestrator_model", "")
        normalized = _normalize_github_model_name(configured)
        return (
            "Configured model is not recognized by endpoint. "
            "Set ORCHESTRATOR_MODEL/SUBAGENT_MODEL/REVIEW_MODEL to a deployed model name "
            "(e.g., gpt-4.1 or gpt-4.1-mini). "
            f"Configured={configured}, SuggestedNormalized={normalized}, "
            f"Endpoint={settings.get('github_endpoint', '')}."
        )
    if "models" in message.lower() and "permission" in message.lower():
        return (
            "Model authorization failed: token lacks model access permission. "
            "Update GITHUB_TOKEN to one with Models read access, then retry. "
            f"Endpoint={settings.get('github_endpoint', '')}, "
            f"Model={settings.get('orchestrator_model', '')}."
        )
    if "401" in message or "unauthorized" in message.lower():
        return (
            "Model authorization failed (401 Unauthorized). "
            "Verify GITHUB_TOKEN is valid for GitHub Models and that endpoint/model are correct. "
            f"Endpoint={settings.get('github_endpoint', '')}, "
            f"Model={settings.get('orchestrator_model', '')}."
        )
    return (
        "Model service request failed. Check credentials, endpoint, and model configuration in .env. "
        f"Endpoint={settings.get('github_endpoint', '')}, "
        f"Model={settings.get('orchestrator_model', '')}."
    )


# ─────────────────────────────────────────────
# MULTI-MODEL DISPATCHER FACTORY
# ─────────────────────────────────────────────

def create_multi_model_dispatcher(
    settings: dict,
    log: LogManager,
    config_multi_model: dict | None = None,
) -> tuple:
    """
    Create (MultiModelDispatcher, ConsensusEngine) when MULTI_MODEL_ENABLED=true.
    Returns (None, None) when multi-model is disabled or not configured.

    Additional endpoints are read from focalpoint_config.yaml multi_model.additional_endpoints.
    Each endpoint's API key is resolved from the environment at this point — never stored
    as a literal in config (P001 compliance).
    """
    if not settings.get("multi_model_enabled", False):
        return None, None

    primary_endpoint_id = "primary"
    primary_base_url = settings.get("github_endpoint", "https://models.inference.ai.azure.com")
    primary_api_key = settings.get("github_token", "")
    primary_model = _normalize_github_model_name(
        settings.get("orchestrator_model", "gpt-4.1")
    )

    # Use Foundry endpoint as primary when configured
    foundry_endpoint = settings.get("foundry_endpoint", "")
    if foundry_endpoint:
        primary_endpoint_id = "foundry-primary"
        primary_base_url = foundry_endpoint
        # Foundry uses DefaultAzureCredential — no static key; signal with empty string
        primary_api_key = os.getenv("AZURE_OPENAI_API_KEY", "")

    additional: list = []
    if isinstance(config_multi_model, dict):
        additional = config_multi_model.get("additional_endpoints") or []

    dispatcher = MultiModelDispatcher.from_config(
        additional_endpoints=additional,
        primary_endpoint_id=primary_endpoint_id,
        primary_base_url=primary_base_url,
        primary_api_key=primary_api_key,
        primary_model=primary_model,
        log=log,
        default_timeout=settings.get("multi_model_timeout", 30.0),
    )

    consensus = ConsensusEngine(
        log=log,
        failover_threshold=settings.get("multi_model_failover_threshold", 0.35),
    )

    log.log(
        LogLevel.INFO,
        "Bootstrap",
        f"MultiModelDispatcher active — {len(dispatcher.endpoints)} endpoint(s), "
        f"failover_threshold={consensus.failover_threshold}",
    )
    return dispatcher, consensus


async def run_model_preflight(settings: dict, log: LogManager) -> bool:
    """
    Validate model access before starting the workflow server.
    Returns True on success, False on failure.
    """
    foundry_endpoint = settings.get("foundry_endpoint", "")
    github_token = settings.get("github_token", "")

    print("[PREFLIGHT] Model access check: START")

    if foundry_endpoint:
        # Deep Foundry auth checks require live Azure identity/environment.
        # We validate configuration presence here and let first request verify runtime auth.
        print("[PREFLIGHT] Model access check: PASS (Foundry endpoint configured)")
        log.log(LogLevel.INFO, "Preflight", "PASS (Foundry endpoint configured)")
        return True

    if github_token:
        try:
            import httpx

            base_url = settings["github_endpoint"].rstrip("/")
            chat_url = f"{base_url}/chat/completions"
            model_name = _normalize_github_model_name(
                settings.get("orchestrator_model", "openai/gpt-4.1")
            )
            headers = {
                "Authorization": f"Bearer {github_token}",
                "Accept": "application/json",
                "Content-Type": "application/json",
            }
            payload = {
                "model": model_name,
                "messages": [{"role": "user", "content": "ping"}],
                "max_tokens": 1,
                "temperature": 0,
            }
            async with httpx.AsyncClient(timeout=20.0) as client:
                resp = await client.post(chat_url, headers=headers, json=payload)

            if resp.status_code == 200:
                print("[PREFLIGHT] Model access check: PASS (chat generation probe succeeded)")
                log.log(LogLevel.INFO, "Preflight", "PASS (chat generation probe succeeded)")
                return True

            if resp.status_code in (401, 403):
                details = (
                    "Model authorization failed. Token cannot access chat generation endpoint. "
                    "Update GITHUB_TOKEN with GitHub Models permission and org SSO authorization if required. "
                    f"Endpoint={base_url}, Model={model_name}, Status={resp.status_code}."
                )
                print(f"[PREFLIGHT] Model access check: FAIL - {details}")
                log.log(LogLevel.ERROR, "Preflight", f"FAIL - {details}")
                return False

            if resp.status_code == 404:
                details = (
                    "Model endpoint/model not found. Verify endpoint and model name. "
                    f"Endpoint={base_url}, Model={model_name}, Status=404."
                )
                print(f"[PREFLIGHT] Model access check: FAIL - {details}")
                log.log(LogLevel.ERROR, "Preflight", f"FAIL - {details}")
                return False

            snippet = (resp.text or "")[:300].replace("\n", " ")
            details = (
                "Model service request failed. Check credentials, endpoint, model, and service availability. "
                f"Endpoint={base_url}, Model={model_name}, Status={resp.status_code}, Body={snippet}"
            )
            print(f"[PREFLIGHT] Model access check: FAIL - {details}")
            log.log(LogLevel.ERROR, "Preflight", f"FAIL - {details}")
            return False

        except Exception as ex:
            details = _auth_help_message(ex, settings)
            raw = f"{type(ex).__name__}: {ex}"
            print(f"[PREFLIGHT] Model access check: FAIL - {details} RawError={raw}")
            log.log(LogLevel.ERROR, "Preflight", f"FAIL - {details} RawError={raw}")
            return False

    details = (
        "No model credentials configured. "
        "Set GITHUB_TOKEN (GitHub Models) or FOUNDRY_PROJECT_ENDPOINT (Foundry)."
    )
    print(f"[PREFLIGHT] Model access check: FAIL - {details}")
    log.log(LogLevel.ERROR, "Preflight", f"FAIL - {details}")
    return False


# ─────────────────────────────────────────────
# SYSTEM BOOTSTRAP
# ─────────────────────────────────────────────

def bootstrap_system(settings: dict) -> tuple:
    """
    Initialise all core system components and generate PKI certs for all known agents.
    Returns (log_manager, pki_manager, checkpoint_manager, viewpoint).
    """
    # Core managers
    log = LogManager(log_dir=settings["log_dir"])
    pki = PKIManager(pki_dir=settings["pki_dir"])
    checkpoint_mgr = CheckpointManager(
        checkpoint_dir=settings["checkpoint_dir"],
        pki_manager=pki,
        focalpoint_id="FocalPoint-null-00",
    )
    viewpoint = ViewPointInit(log_manager=log, pki_manager=pki)

    # Sin registry — persistent cross-session memory of code sins and fixes
    sin_registry = SinRegistry(
        registry_dir=settings.get("sin_registry_dir", "sin_registry"),
        log=log,
    )
    summary = sin_registry.get_summary()
    log.log(LogLevel.INFO, "Bootstrap",
            f"SinRegistry loaded: {summary['total_sins']} sins, "
            f"{summary['trusted_fixes']} trusted fixes, "
            f"{summary['total_regressions']} regressions")

    # Bootstrap PKI for all known agents
    known_agent_ids = [
        "FocalPoint-null-00",
        "ViewPoint-init",
        "SecurityTriage-00",
        "AgentReview-00",
        "QualityControl-00",
        "StandardsGuard-00",
        "Code-B-iSmuth-00",
        "Code-B-Tsted-00",
        "MultiModelProxy-00",
    ]
    log.log(LogLevel.INFO, "Bootstrap", "Bootstrapping PKI for all known agents...")
    certs = pki.ensure_all_agent_certs(known_agent_ids)
    log.log(LogLevel.INFO, "Bootstrap",
            f"PKI ready for {len(certs)}/{len(known_agent_ids)} agents")

    return log, pki, checkpoint_mgr, viewpoint, sin_registry


# ─────────────────────────────────────────────
# WORKFLOW BUILDER
# ─────────────────────────────────────────────

def build_workflow(settings: dict, log: LogManager, pki: PKIManager,
                   checkpoint_mgr: CheckpointManager, viewpoint: ViewPointInit,
                   sin_registry: SinRegistry = None,
                   monitor: RuntimeMonitor | None = None):
    """
    Build the FocalPoint-null workflow.
    FocalPoint-null-00 is the orchestrator (start executor).
    Sub-agents are available as downstream executors for specific task types.
    """
    orchestrator_client = create_client(settings, settings["orchestrator_model"])
    subagent_client = create_client(settings, settings["subagent_model"])
    review_client = create_client(settings, settings["review_model"])

    # Multi-model dispatcher + consensus (None when MULTI_MODEL_ENABLED=false)
    # Load additional_endpoints from focalpoint_config.yaml if available
    _multi_model_cfg: dict | None = None
    try:
        import yaml
        _cfg_path = Path(__file__).parent / "config" / "focalpoint_config.yaml"
        if _cfg_path.exists():
            with open(_cfg_path, encoding="utf-8") as _f:
                _full_cfg = yaml.safe_load(_f) or {}
                _multi_model_cfg = _full_cfg.get("multi_model")
    except Exception as _ex:
        log.log(LogLevel.WARNING, "Bootstrap", f"Could not read focalpoint_config.yaml: {_ex}")

    dispatcher, consensus_engine = create_multi_model_dispatcher(
        settings=settings,
        log=log,
        config_multi_model=_multi_model_cfg,
    )

    # Instantiate executors
    focalpoint = FocalPointOrchestrator(
        client=orchestrator_client,
        log=log,
        checkpoint_mgr=checkpoint_mgr,
        pki=pki,
        viewpoint=viewpoint,
        allow_organic_growth=settings["allow_organic_growth"],
        monitor=monitor,
        dispatcher=dispatcher,
        consensus_engine=consensus_engine,
    )

    agent_review = AgentReviewExecutor(client=review_client, log=log, monitor=monitor)
    security_triage = SecurityTriageExecutor(client=subagent_client, log=log, monitor=monitor)
    quality_control = QualityControlExecutor(client=subagent_client, log=log, monitor=monitor)
    standards_guard = StandardsGuardExecutor(
        client=subagent_client, log=log, todo_dir=settings["todo_dir"], monitor=monitor
    )

    # Code pipeline agents — require SinRegistry
    _sin_reg = sin_registry or SinRegistry(
        registry_dir=settings.get("sin_registry_dir", "sin_registry"), log=log
    )
    code_compiler = CodeCompilerExecutor(
        client=subagent_client,
        log=log,
        sin_registry=_sin_reg,
        modules_dir=settings.get("modules_dir", "modules"),
        scripts_dir=settings.get("scripts_dir", "scripts"),
        monitor=monitor,
    )
    code_tester = CodeTesterExecutor(
        client=subagent_client,
        log=log,
        sin_registry=_sin_reg,
        monitor=monitor,
    )

    # Build workflow DAG:
    # FocalPoint (orchestrates)
    #   -> [AgentReview, SecurityTriage, QualityControl, StandardsGuard]
    #   -> Code-B-iSmuth -> Code-B-Tsted (compile then test pipeline)
    workflow = (
        WorkflowBuilder()
        .set_start_executor(focalpoint)
        .add_edge(focalpoint, agent_review)
        .add_edge(focalpoint, code_compiler)
        .add_edge(code_compiler, code_tester)
        .build()
        .as_agent()  # Expose as HTTP-compatible agent
    )

    log.log(LogLevel.INFO, "Bootstrap", "Workflow built and ready")
    return workflow


# ─────────────────────────────────────────────
# HTTP SERVER MODE
# ─────────────────────────────────────────────

async def run_server(settings: dict) -> None:
    """Start FocalPoint-null as HTTP server (default/production mode)."""
    # Use agentserver-core directly to avoid azure-ai-agentserver-agentframework's
    # unconditional AzureAIClient import (which fails without PromptAgentDefinitionText)
    try:
        from azure.ai.agentserver.agentframework import from_agent_framework
        _server_mode = "agentframework"
    except ImportError:
        _server_mode = "fallback"

    log, pki, checkpoint_mgr, viewpoint, sin_registry = bootstrap_system(settings)
    monitor = RuntimeMonitor()

    def _normalize_local_url(url: str) -> str:
        return (url or "").replace("0.0.0.0", "127.0.0.1")

    base_server = f"http://{settings['http_host']}:{settings['http_port']}"
    dashboard_url = f"http://{settings['dashboard_host']}:{settings['dashboard_port']}"
    base_server_ui = _normalize_local_url(base_server)
    dashboard_url_ui = _normalize_local_url(dashboard_url)
    monitored_agents = [
        "HTTP-Gateway",
        "FocalPoint-null-00",
        "ViewPoint-init",
        "SecurityTriage-00",
        "AgentReview-00",
        "QualityControl-00",
        "StandardsGuard-00",
        "Code-B-iSmuth-00",
        "Code-B-Tsted-00",
    ]
    for agent_id in monitored_agents:
        endpoint = f"{base_server}/chat" if agent_id != "ViewPoint-init" else base_server
        monitor.register_agent(agent_id, _normalize_local_url(endpoint))

    preflight_ok = await run_model_preflight(settings, log)
    if not preflight_ok:
        raise RuntimeError("Startup blocked: model preflight failed. Fix credentials/permissions and retry.")

    workflow = build_workflow(
        settings, log, pki, checkpoint_mgr, viewpoint, sin_registry, monitor=monitor
    )
    log.log(LogLevel.INFO, "FocalPoint-null-00",
            f"Starting HTTP server on {settings['http_host']}:{settings['http_port']}")

    import aiohttp.web as web

    def dashboard_html() -> str:
        return f"""<!doctype html>
<html><head><meta charset='utf-8'><title>FocalPoint Monitor</title>
<style>
body{{font-family:Segoe UI,Arial,sans-serif;background:#0f172a;color:#e2e8f0;margin:0}}
header{{padding:16px 20px;background:#111827;display:flex;justify-content:space-between;align-items:center}}
a{{color:#60a5fa;text-decoration:none}} .wrap{{padding:16px 20px}}
table{{width:100%;border-collapse:collapse;background:#111827;border-radius:8px;overflow:hidden}}
th,td{{padding:10px 8px;border-bottom:1px solid #1f2937;font-size:13px;text-align:left}}
th{{background:#0b1220}} .ok{{color:#22c55e}} .err{{color:#f87171}} .act{{color:#fbbf24}}
.meta{{margin:10px 0 16px 0;color:#94a3b8;font-size:13px}}
.controls{{display:flex;gap:14px;align-items:center;margin:6px 0 12px 0;font-size:13px;color:#cbd5e1}}
.panel{{background:#111827;border:1px solid #1f2937;border-radius:8px;padding:12px;margin:0 0 14px 0}}
.panel h3{{margin:0 0 8px 0;font-size:15px}}
textarea{{width:100%;height:130px;background:#0b1220;color:#e2e8f0;border:1px solid #334155;border-radius:6px;padding:10px;font-family:Consolas,monospace;font-size:12px}}
button,select{{background:#1e293b;color:#e2e8f0;border:1px solid #334155;border-radius:6px;padding:6px 10px}}
pre{{white-space:pre-wrap;background:#0b1220;border:1px solid #334155;border-radius:6px;padding:10px;max-height:240px;overflow:auto}}
</style></head>
<body>
<header><div><strong>FocalPoint-null Agent Monitoring Dashboard</strong></div>
<div><a href='/help'>Help</a> · <a href='{base_server_ui}/health' target='_blank'>API Health</a></div></header>
<div class='wrap'>
<div class='meta'>Dashboard: {dashboard_url_ui} · API: {base_server_ui}</div>
<div class='controls'>
    <label>Refresh Interval:
        <select id='refreshSel'>
            <option value='1000'>1s</option>
            <option value='2000' selected>2s</option>
            <option value='5000'>5s</option>
            <option value='10000'>10s</option>
            <option value='30000'>30s</option>
        </select>
    </label>
    <button id='probeBtn' type='button'>Probe Agents / Ports / Env</button>
    <button id='copyCmdBtn' type='button'>Copy Functions</button>
</div>

<div class='panel'>
    <h3>Quick Functions (PowerShell)</h3>
    <textarea id='cmdBlock' readonly>function Start-FocalPointServer {{
    C:/PowerShellGUI/.venv/Scripts/python.exe c:/PowerShellGUI/agents/focalpoint-null/main.py --server
}}

function Invoke-FocalPointChat([string]$Message = "test") {{
    Invoke-RestMethod -Uri "{base_server_ui}/chat" -Method Post -ContentType "application/json" -Body (ConvertTo-Json @{{ message = $Message }})
}}

function Test-FocalPointProbe {{
    Invoke-RestMethod -Uri "{dashboard_url_ui}/api/probe" -Method Get
}}</textarea>
    <div style='margin-top:8px;'>
        <strong>Probe Output</strong>
        <pre id='probeOut'>Click "Probe Agents / Ports / Env" to run diagnostics.</pre>
    </div>
</div>

<table id='tbl'><thead><tr>
<th>Agent</th><th>Status</th><th>URL/Port</th><th>Last Received</th><th>Last Sent</th>
<th>Received</th><th>Sent</th><th>Error Count</th><th>Last Error</th><th>Uptime</th><th>Active Processing</th><th>Logs</th>
</tr></thead><tbody></tbody></table>
</div>
<script>
function s(v){{return (v===null||v===undefined||v==='')?'—':String(v)}}
function c(status){{if(status==='active')return 'act'; if(status==='error')return 'err'; return 'ok';}}
let refreshTimer = null;
function applyRefresh(){{
    const ms = Number(document.getElementById('refreshSel').value || 2000);
    if(refreshTimer) clearInterval(refreshTimer);
    refreshTimer = setInterval(load, ms);
}}
async function load(){{
  const r=await fetch('/api/monitor'); const d=await r.json();
  const b=document.querySelector('#tbl tbody'); b.innerHTML='';
  for(const a of d.agents){{
    const tr=document.createElement('tr');
    tr.innerHTML=`<td>${{s(a.agent_id)}}</td><td class="${{c(a.status)}}">${{s(a.status)}}</td>
      <td><a href="${{a.endpoint_url}}" target="_blank">${{s(a.endpoint_url)}}</a></td>
      <td>${{s(a.last_received_at)}}</td><td>${{s(a.last_sent_at)}}</td>
            <td>${{s(a.received_count)}}</td><td>${{s(a.sent_count)}}</td>
            <td>${{s(a.error_count)}}</td><td>${{s(a.last_error_message)}}</td>
            <td>${{s(a.uptime_hms)}}</td><td>${{s(a.active_processing_hms)}}</td>
            <td><a href="${{a.log_url}}" target="_blank">open</a></td>`;
    b.appendChild(tr);
  }}
}}
async function runProbe(){{
    const out = document.getElementById('probeOut');
    out.textContent = 'Running probe...';
    try {{
        const r = await fetch('/api/probe');
        const d = await r.json();
        out.textContent = JSON.stringify(d, null, 2);
    }} catch (e) {{
        out.textContent = 'Probe failed: ' + e;
    }}
}}
function copyCmds(){{
    const block = document.getElementById('cmdBlock');
    block.select();
    block.setSelectionRange(0, 99999);
    navigator.clipboard.writeText(block.value);
}}
document.getElementById('refreshSel').addEventListener('change', applyRefresh);
document.getElementById('probeBtn').addEventListener('click', runProbe);
document.getElementById('copyCmdBtn').addEventListener('click', copyCmds);
load(); applyRefresh();
</script>
</body></html>"""

    def help_html() -> str:
        return f"""<!doctype html>
<html><head><meta charset='utf-8'><title>FocalPoint Monitor Help</title>
<style>body{{font-family:Segoe UI,Arial,sans-serif;margin:24px;line-height:1.5;color:#0f172a}}code{{background:#f1f5f9;padding:2px 4px;border-radius:4px}}</style>
</head><body>
<h1>FocalPoint-null Monitoring Help</h1>
<h2>Overview</h2>
<p>This dashboard runs on <code>{dashboard_url_ui}</code> and monitors agent runtime activity while the API server runs on <code>{base_server_ui}</code>.</p>
<h2>What is displayed</h2>
<ul>
  <li>Agent status (idle/active/error)</li>
  <li>Agent URL and port link</li>
  <li>Last message received time</li>
  <li>Last message sent time</li>
    <li>Received and sent counts per agent</li>
  <li>Error count and last error message</li>
  <li>Agent uptime and active processing duration</li>
    <li>Per-agent active log links</li>
</ul>
<h2>Setup</h2>
<ol>
  <li>Set model credentials in <code>.env</code> (<code>GITHUB_TOKEN</code> or Foundry settings).</li>
  <li>Configure ports if needed: <code>HTTP_PORT</code>, <code>DASHBOARD_PORT</code>.</li>
  <li>Start server: <code>python main.py --server</code> or <code>.\\Start-FocalPoint.ps1</code>.</li>
</ol>
<h2>Usage</h2>
<ul>
    <li>Open dashboard: <a href='{dashboard_url_ui}'>{dashboard_url_ui}</a></li>
    <li>Health: <a href='{base_server_ui}/health'>{base_server_ui}/health</a></li>
    <li>Chat endpoint: <code>POST {base_server_ui}/chat</code> with JSON body <code>{{"message":"..."}}</code></li>
    <li>Set refresh interval from the dashboard selector</li>
    <li>Use the probe button to test agents, ports, env vars, and response times</li>
</ul>
<h2>Troubleshooting</h2>
<ul>
  <li>Port conflict: stop old process on port 8087 or 8888 and restart.</li>
  <li>401/403 errors: update token permission for model access.</li>
  <li>Unknown model: use deployed model IDs (for GitHub Models use <code>gpt-4.1</code>-style names).</li>
</ul>
</body></html>"""

    async def dashboard_page(request: web.Request) -> web.Response:
        return web.Response(text=dashboard_html(), content_type="text/html")

    async def help_page(request: web.Request) -> web.Response:
        return web.Response(text=help_html(), content_type="text/html")

    async def monitor_api(request: web.Request) -> web.Response:
        data = monitor.snapshot()
        for agent in data.get("agents", []):
            endpoint = _normalize_local_url(agent.get("endpoint_url", ""))
            agent["endpoint_url"] = endpoint
            agent["log_url"] = f"{dashboard_url_ui}/logs/{quote(agent.get('agent_id', 'unknown'))}"
        data["api_base_url"] = base_server_ui
        data["dashboard_url"] = dashboard_url_ui
        return web.json_response(data)

    def _latest_log_file() -> Path | None:
        files = sorted(Path(log.log_dir).glob("focalpoint-*.jsonl"), key=lambda p: p.stat().st_mtime)
        return files[-1] if files else None

    def _tail_agent_logs(agent_id: str, max_lines: int = 250) -> tuple[str, str]:
        latest = _latest_log_file()
        if not latest:
            return "No active log file found.", ""
        from collections import deque
        lines = deque(maxlen=max_lines)
        with latest.open("r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                if agent_id in line:
                    lines.append(line.rstrip())
        if not lines:
            return f"No log lines found for agent: {agent_id}", latest.name
        return "\n".join(lines), latest.name

    async def logs_page(request: web.Request) -> web.Response:
        agent_id = request.match_info.get("agent_id", "")
        tail, file_name = _tail_agent_logs(agent_id)
        page = (
            "<!doctype html><html><head><meta charset='utf-8'><title>Agent Logs</title>"
            "<style>body{font-family:Segoe UI,Arial,sans-serif;margin:20px}"
            "pre{white-space:pre-wrap;background:#0b1220;color:#e2e8f0;border-radius:8px;padding:12px}"
            "</style></head><body>"
            f"<h2>Agent Log: {html.escape(agent_id)}</h2>"
            f"<div>File: {html.escape(file_name)}</div>"
            f"<pre>{html.escape(tail)}</pre>"
            "</body></html>"
        )
        return web.Response(text=page, content_type="text/html")

    async def probe_api(request: web.Request) -> web.Response:
        import aiohttp

        snapshot = monitor.snapshot()
        agents = snapshot.get("agents", [])
        normalized = []
        for agent in agents:
            endpoint = _normalize_local_url(agent.get("endpoint_url", ""))
            parsed = urlparse(endpoint)
            health_url = f"{parsed.scheme}://{parsed.hostname}:{parsed.port}/health" if parsed.scheme and parsed.hostname and parsed.port else ""
            normalized.append((agent.get("agent_id", "unknown"), endpoint, health_url, parsed.hostname or "", parsed.port or 0))

        timeout = aiohttp.ClientTimeout(total=10)
        service_checks = []
        async with aiohttp.ClientSession(timeout=timeout) as session:
            for agent_id, endpoint, health_url, _, _ in normalized:
                start = time.perf_counter()
                status = 0
                ok = False
                msg = ""
                try:
                    if health_url:
                        async with session.get(health_url) as resp:
                            status = resp.status
                            ok = 200 <= status < 400
                            msg = (await resp.text())[:160]
                    else:
                        msg = "No probe URL"
                except Exception as ex:
                    msg = str(ex)
                elapsed = (time.perf_counter() - start) * 1000.0
                service_checks.append({
                    "agent_id": agent_id,
                    "endpoint_url": endpoint,
                    "probe_url": health_url,
                    "ok": ok,
                    "status": status,
                    "response_time_ms": round(elapsed, 2),
                    "message": msg,
                })

        seen_ports = set()
        port_checks = []
        for _, _, _, host, port in normalized:
            if not host or not port:
                continue
            key = (host, int(port))
            if key in seen_ports:
                continue
            seen_ports.add(key)
            start = time.perf_counter()
            is_open = False
            err = ""
            try:
                reader, writer = await asyncio.wait_for(asyncio.open_connection(host, int(port)), timeout=2.0)
                is_open = True
                writer.close()
                await writer.wait_closed()
            except Exception as ex:
                err = str(ex)
            elapsed = (time.perf_counter() - start) * 1000.0
            port_checks.append({
                "host": host,
                "port": int(port),
                "open": is_open,
                "response_time_ms": round(elapsed, 2),
                "error": err,
            })

        env_keys = [
            "GITHUB_TOKEN",
            "GITHUB_MODEL_ENDPOINT",
            "FOUNDRY_PROJECT_ENDPOINT",
            "ORCHESTRATOR_MODEL",
            "SUBAGENT_MODEL",
            "REVIEW_MODEL",
            "HTTP_HOST",
            "HTTP_PORT",
            "DASHBOARD_HOST",
            "DASHBOARD_PORT",
        ]
        env_report = {}
        for key in env_keys:
            val = os.getenv(key, "")
            if key in {"GITHUB_TOKEN"}:
                env_report[key] = {"present": bool(val), "masked": True}
            else:
                env_report[key] = {"present": bool(val), "value": val}

        return web.json_response({
            "generated_at": snapshot.get("generated_at"),
            "api_base_url": base_server_ui,
            "dashboard_url": dashboard_url_ui,
            "services": service_checks,
            "ports": port_checks,
            "environment": env_report,
        })

    dashboard_app = web.Application()
    dashboard_app.router.add_get("/", dashboard_page)
    dashboard_app.router.add_get("/help", help_page)
    dashboard_app.router.add_get("/api/monitor", monitor_api)
    dashboard_app.router.add_get("/api/probe", probe_api)
    dashboard_app.router.add_get("/logs/{agent_id}", logs_page)
    dashboard_runner = web.AppRunner(dashboard_app)
    await dashboard_runner.setup()
    dashboard_site = web.TCPSite(
        dashboard_runner,
        host=settings["dashboard_host"],
        port=settings["dashboard_port"],
    )
    await dashboard_site.start()
    log.log(LogLevel.INFO, "Monitor",
            f"Dashboard running at {dashboard_url}")

    if settings.get("dashboard_auto_open", True):
        try:
            webbrowser.open(dashboard_url_ui)
        except Exception as ex:
            log.log(LogLevel.WARNING, "Monitor", f"Dashboard auto-open failed: {ex}")

    try:
        if _server_mode == "agentframework":
            await from_agent_framework(workflow).run_async()
            return

        # Fallback: use aiohttp directly when agentserver-agentframework is unavailable

        async def health(request: web.Request) -> web.Response:
            return web.json_response({"status": "ok", "agent": "FocalPoint-null-00"})

        chat_lock = asyncio.Lock()

        async def chat(request: web.Request) -> web.Response:
            if chat_lock.locked():
                msg = "Workflow is busy processing another request. Retry in a moment."
                monitor.mark_error("HTTP-Gateway", msg)
                return web.json_response({"error": msg}, status=429)

            body = await request.json()
            user_text = body.get("message", "")
            msgs = [ChatMessage(role="user", text=user_text)]
            result_text = ""
            event_notes: list[str] = []
            update_fragments: list[str] = []

            def _extract_text(value) -> str:
                if value is None:
                    return ""
                if isinstance(value, str):
                    return value.strip()
                if isinstance(value, list):
                    parts = []
                    for item in value:
                        t = _extract_text(item)
                        if t:
                            parts.append(t)
                    return " ".join(parts).strip()
                if isinstance(value, dict):
                    for key in ("text", "content", "message", "delta", "value"):
                        if key in value:
                            t = _extract_text(value.get(key))
                            if t:
                                return t
                    return ""
                if hasattr(value, "text"):
                    t = _extract_text(getattr(value, "text", ""))
                    if t:
                        return t
                if hasattr(value, "content"):
                    t = _extract_text(getattr(value, "content", ""))
                    if t:
                        return t
                if hasattr(value, "message"):
                    t = _extract_text(getattr(value, "message", ""))
                    if t:
                        return t
                return ""

            from agent_framework import (
                ExecutorFailedEvent,
                WorkflowFailedEvent,
                WorkflowOutputEvent,
                WorkflowStatusEvent,
            )
            monitor.mark_received("HTTP-Gateway")
            monitor.start_processing("HTTP-Gateway")
            try:
                async with chat_lock:
                    async for evt in workflow.run_stream(msgs):
                        if isinstance(evt, WorkflowOutputEvent):
                            result_text = str(evt.data)
                            continue

                        for attr in ("data", "text", "message", "content", "delta", "response", "output"):
                            if hasattr(evt, attr):
                                frag = _extract_text(getattr(evt, attr, None))
                                if frag:
                                    update_fragments.append(frag)
                                    break

                        name = type(evt).__name__
                        executor_id = getattr(evt, "executor_id", None)
                        status = getattr(evt, "status", None)
                        details = getattr(evt, "details", None)
                        detail_msg = ""
                        if details is not None:
                            detail_msg = getattr(details, "message", "") or str(details)

                        note = name
                        if executor_id:
                            note += f"[{executor_id}]"
                        if status:
                            note += f" status={status}"
                        if detail_msg:
                            note += f" msg={detail_msg}"
                        event_notes.append(note)

                        if isinstance(evt, ExecutorFailedEvent):
                            monitor.mark_error("HTTP-Gateway", detail_msg or note)
                        if isinstance(evt, WorkflowFailedEvent):
                            monitor.mark_error("HTTP-Gateway", detail_msg or note)
                        if isinstance(evt, WorkflowStatusEvent):
                            pass

                monitor.mark_sent("HTTP-Gateway")
            except ServiceResponseException as ex:
                details = _auth_help_message(ex, settings)
                log.log(LogLevel.ERROR, "FocalPoint-null-00", details)
                monitor.mark_error("HTTP-Gateway", details)
                return web.json_response({"error": details}, status=401)
            except Exception as ex:
                details = f"Unhandled chat execution error: {ex}"
                log.log(LogLevel.ERROR, "FocalPoint-null-00", details)
                monitor.mark_error("HTTP-Gateway", details)
                return web.json_response({"error": details}, status=500)
            finally:
                monitor.stop_processing("HTTP-Gateway")

            if not result_text.strip() and update_fragments:
                # Use the latest meaningful streamed update when no WorkflowOutputEvent was emitted.
                result_text = update_fragments[-1]

            if not result_text.strip():
                filtered = [n for n in event_notes if n and n != "AgentRunResponseUpdate"]
                trace = " | ".join((filtered or event_notes)[-8:]) if event_notes else "no workflow status/failure events captured"
                result_text = (
                    "Request processed, but no final output was emitted by the workflow. "
                    f"Pipeline trace: {trace}. "
                    "Use dashboard logs for per-agent details."
                )
            return web.json_response({"response": result_text})

        app = web.Application()
        app.router.add_get("/health", health)
        app.router.add_post("/chat", chat)
        log.log(LogLevel.INFO, "FocalPoint-null-00",
                f"HTTP server (fallback/aiohttp) on {settings['http_host']}:{settings['http_port']}")
        runner = web.AppRunner(app)
        await runner.setup()
        site = web.TCPSite(runner, host=settings["http_host"], port=settings["http_port"])
        await site.start()
        log.log(LogLevel.INFO, "FocalPoint-null-00",
                f"Server ready at http://{settings['http_host']}:{settings['http_port']}")
        # Keep running until cancelled
        try:
            await asyncio.Event().wait()
        except asyncio.CancelledError:
            log.log(LogLevel.INFO, "FocalPoint-null-00", "Shutdown signal received; stopping server.")
        finally:
            await runner.cleanup()
    finally:
        await dashboard_runner.cleanup()


# ─────────────────────────────────────────────
# CLI MODE
# ─────────────────────────────────────────────

async def run_cli(settings: dict, user_input: str) -> None:
    """Run a single request in CLI mode for testing."""
    log, pki, checkpoint_mgr, viewpoint, sin_registry = bootstrap_system(settings)

    preflight_ok = await run_model_preflight(settings, log)
    if not preflight_ok:
        print("\n[STARTUP BLOCKED] Model preflight failed. Fix credentials/permissions and retry.")
        return

    workflow = build_workflow(settings, log, pki, checkpoint_mgr, viewpoint, sin_registry)

    from agent_framework import WorkflowOutputEvent, WorkflowFailedEvent, ExecutorFailedEvent

    messages = [ChatMessage(role="user", text=user_input)]

    print(f"\n[FocalPoint-null-00] Processing: {user_input}\n{'=' * 60}")

    try:
        async for event in workflow.run_stream(messages):
            if isinstance(event, WorkflowOutputEvent):
                print(f"\n[OUTPUT] {event.data}")
            elif isinstance(event, ExecutorFailedEvent):
                print(f"\n[EXECUTOR FAILED] {event.executor_id}: {event.details.message}")
            elif isinstance(event, WorkflowFailedEvent):
                print(f"\n[WORKFLOW FAILED] {event.details.message}")
    except ServiceResponseException as ex:
        print(f"\n[AUTH ERROR] {_auth_help_message(ex, settings)}")
    except Exception as ex:
        print(f"\n[UNHANDLED ERROR] {ex}")

    # Print access summary
    summary = log.get_access_summary()
    print(f"\n{'=' * 60}")
    print(f"[ACCESS SUMMARY] FocalPoint calls: {summary['focalpoint']['total_calls']}")
    print(f"[ACCESS SUMMARY] Sub-agent tracked: {summary['total_subagents_tracked']}")
    print(f"[ACCESS SUMMARY] Total secured: {summary['aggregate']['secured_calls']}")
    print(f"[ACCESS SUMMARY] Total unsecured: {summary['aggregate']['unsecured_calls']}")


# ─────────────────────────────────────────────
# ENTRY POINT
# ─────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="FocalPoint-null-00 Orchestrator Agent"
    )
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--server", action="store_true",
                       help="Start in HTTP server mode (default)")
    group.add_argument("--cli", action="store_true",
                       help="Run a single request in CLI mode")
    parser.add_argument("--input", type=str, default="",
                        help="User input for CLI mode")
    args = parser.parse_args()

    settings = get_settings()

    try:
        if args.cli:
            user_input = args.input or input("Enter request: ")
            asyncio.run(run_cli(settings, user_input))
        else:
            # Default: HTTP server mode
            asyncio.run(run_server(settings))
    except KeyboardInterrupt:
        print("\n[FocalPoint-null-00] Shutdown complete.")


if __name__ == "__main__":
    main()






