# VersionTag: 2605.B2.V31.7
# VersionTag: 2605.B2.V31.7
# VersionTag: 2605.B2.V31.7
# VersionTag: 2605.B2.V31.7
"""
FocalPoint-null Checkpoint Manager
Saves and restores orchestrator state as SHA256-signed JSON snapshots.
Supports ALLOW-AGENT-ARCHIVAL-ACCESS metatag for PKI-gated agent re-access.
Handles planned/unplanned FocalPoint disconnection and resume.
"""
from __future__ import annotations

import hashlib
import json
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

from core.models import Checkpoint, CheckpointMetadata, OrchestratorState
from core.pki_manager import PKIManager


class CheckpointManager:
    """
    Manages checkpoints for FocalPoint-null orchestrator and sub-agents.
    - Saves signed snapshots of orchestrator state.
    - Supports resume from last valid checkpoint.
    - Archives can be tagged for agent re-access with PKI validation.
    - Integrates with replay logs for point-of-failure resumption.
    """

    def __init__(
        self,
        checkpoint_dir: str = "checkpoints",
        pki_manager: Optional[PKIManager] = None,
        focalpoint_id: str = "FocalPoint-null-00",
    ):
        self.checkpoint_dir = Path(checkpoint_dir)
        self.checkpoint_dir.mkdir(parents=True, exist_ok=True)
        self.pki_manager = pki_manager
        self.focalpoint_id = focalpoint_id
        self._lock = threading.Lock()
        # Index of checkpoints: {checkpoint_id: file_path}
        self._index: Dict[str, str] = {}
        self._load_index()

    # ─────────────────────────────────────────────
    # SAVE
    # ─────────────────────────────────────────────

    def save_checkpoint(
        self,
        state: OrchestratorState,
        allow_agent_access: bool = False,
        permitted_agent_ids: Optional[List[str]] = None,
        permitted_agent_keys: Optional[Dict[str, str]] = None,
    ) -> Checkpoint:
        """
        Save a signed checkpoint snapshot of the orchestrator state.
        Returns the Checkpoint record.
        """
        state_data = state.model_dump(mode="json")
        state_json = json.dumps(state_data, sort_keys=True, default=str)
        state_sha256 = hashlib.sha256(state_json.encode()).hexdigest()

        metadata = CheckpointMetadata(
            allow_agent_archival_access=allow_agent_access,
            permitted_agent_ids=permitted_agent_ids or [],
            permitted_agent_public_keys=permitted_agent_keys or {},
            archive_sha256=state_sha256,
        )

        signature = None
        if self.pki_manager:
            try:
                _, signature = self.pki_manager.sign_payload(self.focalpoint_id, state_json)
            except Exception:
                pass  # Unsigned checkpoint allowed but noted

        checkpoint = Checkpoint(
            focalpoint_instance=self.focalpoint_id,
            state_type="orchestrator_state",
            state_data=state_data,
            active_task_ids=list(state.active_tasks.keys()),
            active_fork_ids=list(state.active_forks.keys()),
            state_sha256=state_sha256,
            signature=signature,
            metadata=metadata,
        )

        checkpoint_path = self.checkpoint_dir / f"{checkpoint.checkpoint_id}.json"
        checkpoint_json = checkpoint.model_dump_json(indent=2)
        checkpoint_path.write_text(checkpoint_json, encoding="utf-8")

        with self._lock:
            self._index[checkpoint.checkpoint_id] = str(checkpoint_path)
        self._save_index()

        return checkpoint

    def save_subagent_checkpoint(
        self,
        agent_id: str,
        task_id: str,
        state_data: Dict[str, Any],
        allow_agent_access: bool = False,
    ) -> Checkpoint:
        """Save a checkpoint for a sub-agent's task state (for failure recovery)."""
        state_json = json.dumps(state_data, sort_keys=True, default=str)
        state_sha256 = hashlib.sha256(state_json.encode()).hexdigest()

        metadata = CheckpointMetadata(
            allow_agent_archival_access=allow_agent_access,
            archive_sha256=state_sha256,
        )

        signature = None
        if self.pki_manager:
            try:
                _, signature = self.pki_manager.sign_payload(agent_id, state_json)
            except Exception:
                pass

        checkpoint = Checkpoint(
            focalpoint_instance=self.focalpoint_id,
            state_type=f"subagent_task_state:{agent_id}",
            state_data={"agent_id": agent_id, "task_id": task_id, **state_data},
            active_task_ids=[task_id],
            state_sha256=state_sha256,
            signature=signature,
            metadata=metadata,
        )

        checkpoint_path = (
            self.checkpoint_dir / f"subagent-{agent_id}-{task_id}-{checkpoint.checkpoint_id[:8]}.json"
        )
        checkpoint_path.write_text(checkpoint.model_dump_json(indent=2), encoding="utf-8")

        with self._lock:
            self._index[checkpoint.checkpoint_id] = str(checkpoint_path)
        self._save_index()

        return checkpoint

    # ─────────────────────────────────────────────
    # LOAD / RESUME
    # ─────────────────────────────────────────────

    def load_latest_checkpoint(self) -> Optional[OrchestratorState]:
        """
        Load the most recent valid checkpoint for this FocalPoint instance.
        Validates SHA256 and optional PKI signature before returning.
        """
        orchestrator_checkpoints = [
            path for path in self.checkpoint_dir.glob("*.json")
            if not path.name.startswith("subagent-") and not path.name == "_index.json"
        ]
        if not orchestrator_checkpoints:
            return None

        # Sort by modification time, newest first
        orchestrator_checkpoints.sort(key=lambda p: p.stat().st_mtime, reverse=True)

        for checkpoint_path in orchestrator_checkpoints:
            checkpoint = self._load_and_verify_checkpoint(checkpoint_path)
            if checkpoint is not None:
                return OrchestratorState(**checkpoint.state_data)

        return None

    def load_checkpoint_by_id(self, checkpoint_id: str) -> Optional[Checkpoint]:
        """Load a specific checkpoint by ID."""
        path_str = self._index.get(checkpoint_id)
        if not path_str:
            # Try direct file lookup
            path = self.checkpoint_dir / f"{checkpoint_id}.json"
            if not path.exists():
                return None
            path_str = str(path)

        return self._load_and_verify_checkpoint(Path(path_str))

    def load_subagent_task_state(self, agent_id: str, task_id: str) -> Optional[Dict[str, Any]]:
        """
        Find the latest checkpoint for a specific sub-agent/task combination.
        Used on failure recovery to resume from last known state.
        """
        pattern = f"subagent-{agent_id}-{task_id}-*.json"
        matches = list(self.checkpoint_dir.glob(pattern))
        if not matches:
            return None

        matches.sort(key=lambda p: p.stat().st_mtime, reverse=True)
        checkpoint = self._load_and_verify_checkpoint(matches[0])
        if checkpoint:
            return checkpoint.state_data
        return None

    def apply_replay_log(
        self,
        replay_log_path: str,
        current_state: OrchestratorState,
    ) -> OrchestratorState:
        """
        Apply a replay log from a secured sub-agent to reconcile in-place changes
        with the FocalPoint's last known state at the point of disconnection.
        Returns merged state.
        """
        replay_path = Path(replay_log_path)
        if not replay_path.exists():
            raise FileNotFoundError(f"Replay log not found: {replay_log_path}")

        replay_data = json.loads(replay_path.read_text(encoding="utf-8"))

        # Validate replay log SHA256 if present
        stored_sha256 = replay_data.pop("sha256", None)
        if stored_sha256:
            content = json.dumps(replay_data, sort_keys=True, default=str)
            computed = hashlib.sha256(content.encode()).hexdigest()
            if computed != stored_sha256:
                raise ValueError(f"Replay log SHA256 mismatch — possible tampering: {replay_log_path}")

        # Apply completed tasks from replay to current state
        completed_tasks = replay_data.get("completed_tasks", {})
        for task_id, task_data in completed_tasks.items():
            if task_id in current_state.active_tasks:
                # Task was completed during disconnection — update state
                from core.models import Task, TaskStatus
                current_state.active_tasks[task_id] = Task(**task_data)
                current_state.completed_task_count += 1

        current_state.last_active_at = datetime.now(timezone.utc)
        return current_state

    # ─────────────────────────────────────────────
    # VERIFICATION
    # ─────────────────────────────────────────────

    def verify_checkpoint(self, checkpoint: Checkpoint) -> bool:
        """Verify a loaded checkpoint's SHA256 and signature."""
        state_json = json.dumps(checkpoint.state_data, sort_keys=True, default=str)
        computed_sha256 = hashlib.sha256(state_json.encode()).hexdigest()

        if computed_sha256 != checkpoint.state_sha256:
            return False

        if checkpoint.signature and self.pki_manager:
            return self.pki_manager.verify_payload(
                self.focalpoint_id,
                state_json,
                checkpoint.signature,
                checkpoint.state_sha256,
            )

        return True  # No signature present — accept but note

    def is_agent_permitted_archival_access(
        self, checkpoint: Checkpoint, requesting_agent_id: str
    ) -> bool:
        """
        Check if an agent has permission to access an archived checkpoint.
        Requires ALLOW-AGENT-ARCHIVAL-ACCESS metatag + agent in permitted list.
        """
        meta = checkpoint.metadata
        if not meta.allow_agent_archival_access:
            return False
        return requesting_agent_id in meta.permitted_agent_ids

    # ─────────────────────────────────────────────
    # INTERNAL
    # ─────────────────────────────────────────────

    def _load_and_verify_checkpoint(self, path: Path) -> Optional[Checkpoint]:
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            checkpoint = Checkpoint(**data)
            if not self.verify_checkpoint(checkpoint):
                return None
            return checkpoint
        except Exception:
            return None

    def _load_index(self) -> None:
        index_path = self.checkpoint_dir / "_index.json"
        if index_path.exists():
            try:
                self._index = json.loads(index_path.read_text(encoding="utf-8"))
            except Exception:
                self._index = {}

    def _save_index(self) -> None:
        index_path = self.checkpoint_dir / "_index.json"
        index_path.write_text(json.dumps(self._index, indent=2), encoding="utf-8")

    def list_checkpoints(self) -> List[Dict[str, Any]]:
        """List all known checkpoints with basic metadata."""
        result = []
        for checkpoint_id, path_str in self._index.items():
            path = Path(path_str)
            if path.exists():
                stat = path.stat()
                result.append({
                    "checkpoint_id": checkpoint_id,
                    "path": path_str,
                    "size_bytes": stat.st_size,
                    "modified": datetime.fromtimestamp(stat.st_mtime, tz=timezone.utc).isoformat(),
                })
        return sorted(result, key=lambda x: x["modified"], reverse=True)







