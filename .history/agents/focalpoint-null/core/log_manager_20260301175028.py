"""
FocalPoint-null Log Manager
Structured logging with access counting (FocalPoint vs sub-agents), 
secured/unsecured call analysis, process/thread tracking, and secured checkpointed archival.
"""
from __future__ import annotations

import hashlib
import json
import os
import threading
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

import structlog

from core.models import AccessLogEntry, LogLevel, ResourceType


# Configure structlog for structured JSON output
structlog.configure(
    processors=[
        structlog.processors.TimeStamper(fmt="iso"),
        structlog.stdlib.add_log_level,
        structlog.processors.StackInfoRenderer(),
        structlog.processors.JSONRenderer(),
    ],
)


class AccessCounter:
    """Thread-safe counter for resource access events."""

    def __init__(self):
        self._lock = threading.Lock()
        # Per-resource-type counts: {resource_type: count}
        self.counts: Dict[str, int] = defaultdict(int)
        # Secured vs unsecured call counts
        self.secured_count: int = 0
        self.unsecured_count: int = 0
        # Linked process IDs and thread IDs
        self.process_ids: set[int] = set()
        self.thread_ids: set[str] = set()
        # Per call-method analysis
        self.call_methods: Dict[str, int] = defaultdict(int)

    def record(self, entry: AccessLogEntry) -> None:
        with self._lock:
            self.counts[entry.resource_type.value] += 1
            if entry.is_secured:
                self.secured_count += 1
            else:
                self.unsecured_count += 1
            if entry.process_id:
                self.process_ids.add(entry.process_id)
            if entry.thread_id:
                self.thread_ids.add(entry.thread_id)
            if entry.call_method:
                self.call_methods[entry.call_method] += 1

    def summary(self) -> Dict[str, Any]:
        with self._lock:
            total = self.secured_count + self.unsecured_count
            return {
                "total_calls": total,
                "secured_calls": self.secured_count,
                "unsecured_calls": self.unsecured_count,
                "secured_pct": round(self.secured_count / max(total, 1) * 100, 1),
                "counts_by_type": dict(self.counts),
                "call_methods": dict(self.call_methods),
                "unique_process_ids": sorted(self.process_ids),
                "unique_thread_ids": sorted(self.thread_ids),
            }


class LogManager:
    """
    Manages structured logging for FocalPoint-null system.
    - Maintains separate access counters for FocalPoint vs each sub-agent.
    - Logs all prompts (in/out), actions, checkpoints, resource accesses.
    - Produces secured/unsecured call analysis summary.
    - Supports SHA256-signed log archives with ALLOW-AGENT-ARCHIVAL-ACCESS metatag.
    """

    ALLOW_ARCHIVAL_TAG = "ALLOW-AGENT-ARCHIVAL-ACCESS"

    def __init__(self, log_dir: str = "logs"):
        self.log_dir = Path(log_dir)
        self.log_dir.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()
        self._logger = structlog.get_logger("focalpoint-null")

        # Separate counters
        self._focalpoint_counter = AccessCounter()
        self._subagent_counters: Dict[str, AccessCounter] = {}

        # In-memory log buffer (also written to disk)
        self._log_entries: List[Dict[str, Any]] = []
        self._log_file = self.log_dir / f"focalpoint-{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S')}.jsonl"

    # ─────────────────────────────────────────────
    # ACCESS LOGGING
    # ─────────────────────────────────────────────

    def log_access(self, entry: AccessLogEntry) -> None:
        """Record a resource access event with process/thread tracking."""
        entry.process_id = entry.process_id or os.getpid()
        entry.thread_id = entry.thread_id or str(threading.current_thread().ident)

        if entry.is_focalpoint:
            self._focalpoint_counter.record(entry)
        else:
            if entry.agent_id not in self._subagent_counters:
                self._subagent_counters[entry.agent_id] = AccessCounter()
            self._subagent_counters[entry.agent_id].record(entry)

        self._append_log_entry("ACCESS", entry.model_dump(mode="json"))

    def record_file_access(self, agent_id: str, file_path: str, is_focalpoint: bool = False,
                           is_secured: bool = True, task_id: Optional[str] = None,
                           call_method: str = "LOCAL_FILE") -> AccessLogEntry:
        entry = AccessLogEntry(
            agent_id=agent_id,
            is_focalpoint=is_focalpoint,
            resource_type=ResourceType.FILE,
            resource_ref=file_path,
            is_secured=is_secured,
            call_method=call_method,
            task_id=task_id,
        )
        self.log_access(entry)
        return entry

    def record_website_access(self, agent_id: str, url: str, is_focalpoint: bool = False,
                              is_secured: bool = True, task_id: Optional[str] = None,
                              call_method: str = "HTTPS") -> AccessLogEntry:
        entry = AccessLogEntry(
            agent_id=agent_id,
            is_focalpoint=is_focalpoint,
            resource_type=ResourceType.WEBSITE,
            resource_ref=url,
            is_secured=is_secured,
            call_method=call_method,
            task_id=task_id,
        )
        self.log_access(entry)
        return entry

    def record_memory_access(self, agent_id: str, key: str, is_focalpoint: bool = False,
                             is_secured: bool = True, task_id: Optional[str] = None) -> AccessLogEntry:
        entry = AccessLogEntry(
            agent_id=agent_id,
            is_focalpoint=is_focalpoint,
            resource_type=ResourceType.MEMORY,
            resource_ref=key,
            is_secured=is_secured,
            call_method="INTERNAL_MEMORY",
            task_id=task_id,
        )
        self.log_access(entry)
        return entry

    # ─────────────────────────────────────────────
    # GENERAL LOGGING
    # ─────────────────────────────────────────────

    def log(self, level: LogLevel, agent_id: str, message: str,
            task_id: Optional[str] = None, extra: Optional[Dict] = None) -> None:
        """Log any event with structured context."""
        payload = {
            "level": level.value,
            "agent_id": agent_id,
            "message": message,
            "task_id": task_id,
            "pid": os.getpid(),
            "thread": str(threading.current_thread().ident),
        }
        if extra:
            payload.update(extra)
        self._append_log_entry(level.value, payload)

    def log_prompt(self, agent_id: str, prompt_input: str, prompt_output: str,
                   task_id: Optional[str] = None, is_focalpoint: bool = False) -> None:
        """Log prompt input/output pair. Counts as prompt_input + prompt_output resources."""
        for res_type, text in [(ResourceType.PROMPT_INPUT, prompt_input),
                                (ResourceType.PROMPT_OUTPUT, prompt_output)]:
            entry = AccessLogEntry(
                agent_id=agent_id,
                is_focalpoint=is_focalpoint,
                resource_type=res_type,
                resource_ref=f"prompt:{hashlib.sha256(text.encode()).hexdigest()[:8]}",
                is_secured=True,
                call_method="LLM_API",
                task_id=task_id,
            )
            self.log_access(entry)

        self._append_log_entry("PROMPT", {
            "agent_id": agent_id,
            "task_id": task_id,
            "input_sha256": hashlib.sha256(prompt_input.encode()).hexdigest(),
            "output_sha256": hashlib.sha256(prompt_output.encode()).hexdigest(),
            # Store first 500 chars for audit; full text for sensitive agents may be omitted
            "input_preview": prompt_input[:500],
            "output_preview": prompt_output[:500],
        })

    def log_checkpoint(self, checkpoint_id: str, agent_id: str, task_id: Optional[str] = None) -> None:
        entry = AccessLogEntry(
            agent_id=agent_id,
            is_focalpoint=(agent_id.startswith("FocalPoint")),
            resource_type=ResourceType.CHECKPOINT,
            resource_ref=checkpoint_id,
            is_secured=True,
            call_method="INTERNAL_CHECKPOINT",
            task_id=task_id,
        )
        self.log_access(entry)

    # ─────────────────────────────────────────────
    # SUMMARY REPORT
    # ─────────────────────────────────────────────

    def get_access_summary(self) -> Dict[str, Any]:
        """Produce a summary breakdown of all secured/unsecured access, FocalPoint vs sub-agents."""
        summary = {
            "generated_at": datetime.now(timezone.utc).isoformat(),
            "focalpoint": self._focalpoint_counter.summary(),
            "subagents": {
                agent_id: counter.summary()
                for agent_id, counter in self._subagent_counters.items()
            },
            "total_subagents_tracked": len(self._subagent_counters),
        }
        # Aggregate totals
        total_secured = self._focalpoint_counter.secured_count + sum(
            c.secured_count for c in self._subagent_counters.values()
        )
        total_unsecured = self._focalpoint_counter.unsecured_count + sum(
            c.unsecured_count for c in self._subagent_counters.values()
        )
        summary["aggregate"] = {
            "secured_calls": total_secured,
            "unsecured_calls": total_unsecured,
            "total_calls": total_secured + total_unsecured,
        }
        return summary

    # ─────────────────────────────────────────────
    # ARCHIVE
    # ─────────────────────────────────────────────

    def create_archive(
        self,
        archive_name: Optional[str] = None,
        allow_agent_access: bool = False,
        permitted_agent_ids: Optional[List[str]] = None,
        permitted_agent_keys: Optional[Dict[str, str]] = None,
    ) -> tuple[str, str]:
        """
        Write current log buffer to archive file with SHA256 hash.
        If allow_agent_access=True, injects ALLOW-AGENT-ARCHIVAL-ACCESS metatag.
        Returns (archive_file_path, sha256_hash).
        """
        timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S")
        name = archive_name or f"archive-{timestamp}.jsonl"
        archive_path = self.log_dir / name

        archive_data = {
            "metatags": {
                self.ALLOW_ARCHIVAL_TAG: allow_agent_access,
                "permitted_agent_ids": permitted_agent_ids or [],
                "permitted_agent_public_keys": permitted_agent_keys or {},
                "created_at": timestamp,
            },
            "entries": self._log_entries.copy(),
            "access_summary": self.get_access_summary(),
        }

        content = json.dumps(archive_data, indent=2, default=str)
        sha256 = hashlib.sha256(content.encode()).hexdigest()
        archive_data["sha256"] = sha256

        final_content = json.dumps(archive_data, indent=2, default=str)
        archive_path.write_text(final_content, encoding="utf-8")

        self.log(LogLevel.AUDIT, "LogManager",
                 f"Archive created: {archive_path} SHA256={sha256}",
                 extra={"archive_path": str(archive_path), "sha256": sha256})

        return str(archive_path), sha256

    def verify_archive(self, archive_path: str) -> tuple[bool, str]:
        """Verify the SHA256 hash of an archive. Returns (is_valid, stored_sha256)."""
        path = Path(archive_path)
        if not path.exists():
            return False, ""
        data = json.loads(path.read_text(encoding="utf-8"))
        stored_sha256 = data.pop("sha256", "")
        content_without_hash = json.dumps(data, indent=2, default=str)
        computed = hashlib.sha256(content_without_hash.encode()).hexdigest()
        return computed == stored_sha256, stored_sha256

    # ─────────────────────────────────────────────
    # INTERNAL
    # ─────────────────────────────────────────────

    def _append_log_entry(self, event_type: str, data: Dict[str, Any]) -> None:
        entry = {
            "event_type": event_type,
            "timestamp": datetime.now(timezone.utc).isoformat(),
            **data,
        }
        with self._lock:
            self._log_entries.append(entry)
        # Also write to rolling log file
        try:
            with open(self._log_file, "a", encoding="utf-8") as f:
                f.write(json.dumps(entry, default=str) + "\n")
        except Exception:
            pass  # Don't let logging errors crash the system
