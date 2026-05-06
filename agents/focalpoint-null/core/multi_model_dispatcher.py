# VersionTag: 2605.B2.V31.7
"""
MultiModelDispatcher — Parallel AI model dispatch for FocalPoint-null
Author: The Establishment
FileRole: Module

Dispatches the same chat prompt to N configured model endpoints simultaneously using
asyncio.gather(). Each endpoint's response is recorded as a cryptographically hashed
WitnessEntry for audit/trust/transaction integrity. Provides graceful per-endpoint
failover on timeout or HTTP error — a failed endpoint never blocks the others.

Usage:
    dispatcher = MultiModelDispatcher.from_config(
        additional_endpoints=config_list,
        primary_endpoint_id="github-gpt41",
        primary_base_url="https://models.inference.ai.azure.com",
        primary_api_key=os.getenv("GITHUB_TOKEN", ""),
        primary_model="gpt-4.1",
        log=log,
    )
    transaction = await dispatcher.dispatch(messages=msg_dicts, task_id=task_id)
"""
from __future__ import annotations

import asyncio
import hashlib
import json
import os
import time
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional
from uuid import uuid4

import httpx

from core.log_manager import LogManager, LogLevel
from core.models import (
    DispatchTransaction,
    ModelEndpointConfig,
    ModelResponse,
    WitnessEntry,
)


class MultiModelDispatcher:
    """
    Parallel AI model endpoint dispatcher for FocalPoint-null multi-model consensus.

    Sends the same chat messages to all configured endpoints simultaneously via
    asyncio.gather(). Each response is preserved as a WitnessEntry (SHA256 hash +
    metadata) for cryptographic audit. Failures on individual endpoints are caught
    and stored as error responses — they never propagate to other dispatch coroutines.

    The returned DispatchTransaction is passed to ConsensusEngine for cross-validation,
    scoring and winner selection.
    """

    AGENT_ID = "MultiModelProxy-00"

    def __init__(
        self,
        endpoints: List[ModelEndpointConfig],
        log: LogManager,
        default_timeout_seconds: float = 30.0,
    ) -> None:
        self.endpoints = [ep for ep in endpoints if ep.is_enabled]
        self.log = log
        self.default_timeout = default_timeout_seconds

    # ─────────────────────────────────────────────
    # PUBLIC: PARALLEL DISPATCH
    # ─────────────────────────────────────────────

    async def dispatch(
        self,
        messages: List[Dict[str, Any]],
        transaction_id: Optional[str] = None,
        task_id: Optional[str] = None,
    ) -> DispatchTransaction:
        """
        Dispatch chat messages to all configured endpoints in parallel.

        Returns a DispatchTransaction containing all model responses and their
        WitnessEntries. Successful and failed responses are both recorded.
        """
        txn_id = transaction_id or str(uuid4())
        started_at = datetime.now(timezone.utc)

        self.log.log(
            LogLevel.INFO,
            self.AGENT_ID,
            f"Parallel dispatch to {len(self.endpoints)} endpoint(s) — txn={txn_id}",
            task_id=task_id,
        )

        # One coroutine per endpoint — all run concurrently
        coros = [
            self._query_endpoint(endpoint, messages, txn_id, task_id)
            for endpoint in self.endpoints
        ]
        raw_responses: List[ModelResponse] = await asyncio.gather(*coros)

        # Witness each response
        witness_entries: List[WitnessEntry] = []
        for resp in raw_responses:
            entry = self._make_witness(resp, txn_id)
            witness_entries.append(entry)
            self.log.log(
                LogLevel.AUDIT,
                self.AGENT_ID,
                f"Witness [{resp.endpoint_id}] sha256={entry.response_sha256[:16]}... "
                f"latency={resp.latency_ms}ms error={resp.error or 'none'}",
                task_id=task_id,
            )

        successful = [r for r in raw_responses if r.error is None and r.text]
        failed = [r for r in raw_responses if r.error is not None or not r.text]

        self.log.log(
            LogLevel.INFO,
            self.AGENT_ID,
            f"Dispatch complete — txn={txn_id} success={len(successful)} failed={len(failed)}",
            task_id=task_id,
        )

        messages_sha256 = hashlib.sha256(
            json.dumps(messages, default=str, sort_keys=True).encode()
        ).hexdigest()

        return DispatchTransaction(
            transaction_id=txn_id,
            task_id=task_id,
            messages_sha256=messages_sha256,
            responses=raw_responses,
            witness_entries=witness_entries,
            started_at=started_at,
            completed_at=datetime.now(timezone.utc),
            endpoint_count=len(self.endpoints),
            success_count=len(successful),
            failure_count=len(failed),
        )

    # ─────────────────────────────────────────────
    # INTERNAL: SINGLE-ENDPOINT QUERY
    # ─────────────────────────────────────────────

    async def _query_endpoint(
        self,
        endpoint: ModelEndpointConfig,
        messages: List[Dict[str, Any]],
        txn_id: str,
        task_id: Optional[str],
    ) -> ModelResponse:
        """
        Query one endpoint. Returns ModelResponse with error field set on failure.
        Never raises — all exceptions are caught and returned as error responses.
        """
        start = time.monotonic()
        endpoint_id = endpoint.endpoint_id
        timeout = endpoint.timeout_seconds if endpoint.timeout_seconds > 0 else self.default_timeout

        try:
            headers = {
                "Authorization": f"Bearer {endpoint.api_key}",
                "Content-Type": "application/json",
                "Accept": "application/json",
                "X-FocalPoint-TxnId": txn_id,
            }
            payload: Dict[str, Any] = {
                "model": endpoint.model_name,
                "messages": messages,
                "temperature": endpoint.temperature,
            }
            if endpoint.max_tokens is not None:
                payload["max_tokens"] = endpoint.max_tokens

            async with httpx.AsyncClient(timeout=httpx.Timeout(timeout)) as client:
                resp = await client.post(
                    f"{endpoint.base_url.rstrip('/')}/chat/completions",
                    headers=headers,
                    json=payload,
                )

            latency_ms = int((time.monotonic() - start) * 1000)

            if resp.status_code != 200:
                error_summary = f"HTTP {resp.status_code}: {resp.text[:300]}"
                self.log.log(
                    LogLevel.WARNING, self.AGENT_ID,
                    f"Endpoint {endpoint_id} returned non-200 ({resp.status_code})",
                    task_id=task_id,
                )
                return ModelResponse(
                    endpoint_id=endpoint_id,
                    transaction_id=txn_id,
                    model_name=endpoint.model_name,
                    text="",
                    latency_ms=latency_ms,
                    error=error_summary,
                    weight=endpoint.weight,
                )

            data = resp.json()
            choices = data.get("choices") or []
            text = ""
            if choices:
                text = ((choices[0].get("message") or {}).get("content") or "") or ""

            usage = data.get("usage") or {}
            return ModelResponse(
                endpoint_id=endpoint_id,
                transaction_id=txn_id,
                model_name=endpoint.model_name,
                text=text,
                latency_ms=latency_ms,
                error=None,
                weight=endpoint.weight,
                prompt_tokens=usage.get("prompt_tokens"),
                completion_tokens=usage.get("completion_tokens"),
            )

        except asyncio.TimeoutError:
            latency_ms = int((time.monotonic() - start) * 1000)
            self.log.log(
                LogLevel.WARNING, self.AGENT_ID,
                f"Endpoint {endpoint_id} timed out after {timeout:.0f}s",
                task_id=task_id,
            )
            return ModelResponse(
                endpoint_id=endpoint_id,
                transaction_id=txn_id,
                model_name=endpoint.model_name,
                text="",
                latency_ms=latency_ms,
                error=f"TimeoutError after {timeout:.0f}s",
                weight=endpoint.weight,
            )

        except Exception as ex:
            latency_ms = int((time.monotonic() - start) * 1000)
            self.log.log(
                LogLevel.ERROR, self.AGENT_ID,
                f"Endpoint {endpoint_id} raised {type(ex).__name__}: {ex}",
                task_id=task_id,
            )
            return ModelResponse(
                endpoint_id=endpoint_id,
                transaction_id=txn_id,
                model_name=endpoint.model_name,
                text="",
                latency_ms=latency_ms,
                error=f"{type(ex).__name__}: {ex}",
                weight=endpoint.weight,
            )

    # ─────────────────────────────────────────────
    # INTERNAL: WITNESS ENTRY
    # ─────────────────────────────────────────────

    @staticmethod
    def _make_witness(response: ModelResponse, txn_id: str) -> WitnessEntry:
        """Create a SHA256-hashed WitnessEntry for one model response."""
        payload_str = json.dumps({
            "endpoint_id": response.endpoint_id,
            "transaction_id": txn_id,
            "model_name": response.model_name,
            "text": response.text,
            "latency_ms": response.latency_ms,
            "error": response.error,
        }, sort_keys=True)
        sha256 = hashlib.sha256(payload_str.encode()).hexdigest()
        return WitnessEntry(
            witness_id=str(uuid4()),
            transaction_id=txn_id,
            endpoint_id=response.endpoint_id,
            model_name=response.model_name,
            response_sha256=sha256,
            response_length=len(response.text),
            has_error=response.error is not None,
            latency_ms=response.latency_ms,
            weight=response.weight,
        )

    # ─────────────────────────────────────────────
    # FACTORY: FROM CONFIG
    # ─────────────────────────────────────────────

    @classmethod
    def from_config(
        cls,
        additional_endpoints: List[Dict[str, Any]],
        primary_endpoint_id: str,
        primary_base_url: str,
        primary_api_key: str,
        primary_model: str,
        log: LogManager,
        default_timeout: float = 30.0,
    ) -> "MultiModelDispatcher":
        """
        Factory constructor from focalpoint_config.yaml multi_model section.
        Primary endpoint is always included at weight=1.0.
        Additional endpoints are loaded from config — api_key_env values are resolved
        from environment variables at this point (never stored as literals).
        """
        endpoints: List[ModelEndpointConfig] = [
            ModelEndpointConfig(
                endpoint_id=primary_endpoint_id,
                base_url=primary_base_url,
                api_key=primary_api_key,
                model_name=primary_model,
                weight=1.0,
                timeout_seconds=default_timeout,
                is_primary=True,
            )
        ]

        for ep_cfg in additional_endpoints:
            ep_id = ep_cfg.get("endpoint_id") or str(uuid4())
            # Resolve API key from env var reference — P001: no hardcoded keys
            key_env_name = ep_cfg.get("api_key_env", "")
            key_literal = ep_cfg.get("api_key", "")
            resolved_key = os.getenv(key_env_name, "") if key_env_name else key_literal
            if not resolved_key:
                log.log(
                    LogLevel.WARNING,
                    cls.AGENT_ID,
                    f"Skipping endpoint '{ep_id}' — no API key found "
                    f"(api_key_env={key_env_name or 'not set'})",
                )
                continue

            endpoints.append(ModelEndpointConfig(
                endpoint_id=ep_id,
                base_url=ep_cfg.get("base_url", ""),
                api_key=resolved_key,
                model_name=ep_cfg.get("model_name", ""),
                weight=float(ep_cfg.get("weight", 0.8)),
                timeout_seconds=float(ep_cfg.get("timeout_seconds", default_timeout)),
                temperature=float(ep_cfg.get("temperature", 0.7)),
                max_tokens=ep_cfg.get("max_tokens"),
                is_primary=False,
            ))

        log.log(
            LogLevel.INFO,
            cls.AGENT_ID,
            f"MultiModelDispatcher ready with {len(endpoints)} endpoint(s): "
            + ", ".join(ep.endpoint_id for ep in endpoints),
        )
        return cls(endpoints=endpoints, log=log, default_timeout_seconds=default_timeout)

