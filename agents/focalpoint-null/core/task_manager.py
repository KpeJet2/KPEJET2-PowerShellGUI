# VersionTag: 2604.B0.v1
# VersionTag: 2604.B0.v1
# VersionTag: 2604.B0.v1
# VersionTag: 2604.B0.v1
"""
FocalPoint-null Task Manager
Manages task lifecycle: dispatch, tracking, retry, fork creation, progress monitoring.
Every task has a directive snapshot saved at the time of receipt.
"""
from __future__ import annotations

import hashlib
import threading
import uuid
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional

from core.models import (
    ForkPath,
    ForkSet,
    ForkStatus,
    OrchestratorState,
    Task,
    TaskDirective,
    TaskStatus,
)
from core.log_manager import LogManager, LogLevel


class TaskManager:
    """
    Manages task lifecycle for FocalPoint-null orchestrator.
    - Creates tasks with a snapshot of the agent directive at the time of receipt.
    - Tracks all active/completed/failed tasks.
    - Handles retry logic with configurable backoff.
    - Creates fork paths when agents provide multiple options.
    - Blocks further fork growth after testing is complete.
    """

    def __init__(
        self,
        state: OrchestratorState,
        log_manager: LogManager,
        max_retries: int = 3,
        max_fork_depth: int = 3,
        max_fork_paths: int = 10,
        lock_forks_after_test: bool = True,
    ):
        self.state = state
        self.log = log_manager
        self.max_retries = max_retries
        self.max_fork_depth = max_fork_depth
        self.max_fork_paths = max_fork_paths
        self.lock_forks_after_test = lock_forks_after_test
        self._lock = threading.Lock()

    # ─────────────────────────────────────────────
    # TASK CREATION
    # ─────────────────────────────────────────────

    def create_task(
        self,
        title: str,
        description: str,
        assigned_to: str,
        dispatched_by: str,
        directive_text: str,
        parent_task_id: Optional[str] = None,
        fork_id: Optional[str] = None,
        fork_option_label: Optional[str] = None,
    ) -> Task:
        """
        Create a new task. Saves a SHA256-signed copy of the directive at time of receipt.
        """
        directive_sha256 = hashlib.sha256(directive_text.encode()).hexdigest()
        directive = TaskDirective(
            agent_id=assigned_to,
            directive_text=directive_text,
            directive_sha256=directive_sha256,
            signed_by=dispatched_by,
        )

        task = Task(
            title=title,
            description=description,
            assigned_to=assigned_to,
            dispatched_by=dispatched_by,
            directive_snapshot=directive,
            parent_task_id=parent_task_id,
            fork_id=fork_id,
            fork_option_label=fork_option_label,
            max_retries=self.max_retries,
        )

        with self._lock:
            self.state.active_tasks[task.task_id] = task

        self.log.log(LogLevel.INFO, dispatched_by,
                     f"Task created: {task.task_id} [{title}] assigned to {assigned_to}",
                     task_id=task.task_id,
                     extra={"directive_sha256": directive_sha256})
        return task

    # ─────────────────────────────────────────────
    # TASK STATUS UPDATES
    # ─────────────────────────────────────────────

    def mark_dispatched(self, task_id: str) -> None:
        task = self._get_task(task_id)
        task.status = TaskStatus.DISPATCHED
        task.dispatched_at = datetime.now(timezone.utc)
        self.log.log(LogLevel.INFO, task.dispatched_by, f"Task dispatched: {task_id}", task_id=task_id)

    def mark_in_progress(self, task_id: str, agent_id: str) -> None:
        task = self._get_task(task_id)
        task.status = TaskStatus.IN_PROGRESS
        task.started_at = datetime.now(timezone.utc)
        self.log.log(LogLevel.INFO, agent_id, f"Task started: {task_id}", task_id=task_id)

    def update_progress(self, task_id: str, progress_pct: float, note: str = "") -> None:
        task = self._get_task(task_id)
        task.progress_pct = max(0.0, min(100.0, progress_pct))
        if note:
            task.progress_notes.append(f"[{datetime.now(timezone.utc).isoformat()}] {note}")
        self.log.log(LogLevel.INFO, task.assigned_to,
                     f"Task progress {progress_pct:.0f}%: {note}", task_id=task_id)

    def mark_completed(
        self,
        task_id: str,
        result: Any,
        agent_id: str,
        result_viewpoint_encoded: bool = False,
    ) -> Task:
        task = self._get_task(task_id)
        result_json = str(result)
        task.result = result
        task.result_sha256 = hashlib.sha256(result_json.encode()).hexdigest()
        task.result_viewpoint_encoded = result_viewpoint_encoded
        task.status = TaskStatus.COMPLETED
        task.progress_pct = 100.0
        task.completed_at = datetime.now(timezone.utc)

        with self._lock:
            # Move to completed history
            self.state.completed_task_count += 1
            # Keep in active_tasks for active fork tracking; archive on next checkpoint

        self.log.log(LogLevel.INFO, agent_id,
                     f"Task completed: {task_id} result_sha256={task.result_sha256}",
                     task_id=task_id)
        return task

    def mark_failed(self, task_id: str, error: str, agent_id: str) -> Task:
        task = self._get_task(task_id)
        task.last_error = error
        task.retry_count += 1

        if task.retry_count <= task.max_retries:
            task.status = TaskStatus.RETRYING
            self.log.log(LogLevel.WARNING, agent_id,
                         f"Task failed (retry {task.retry_count}/{task.max_retries}): {task_id} — {error}",
                         task_id=task_id)
        else:
            task.status = TaskStatus.FAILED
            task.completed_at = datetime.now(timezone.utc)
            with self._lock:
                self.state.failed_task_count += 1
            self.log.log(LogLevel.ERROR, agent_id,
                         f"Task PERMANENTLY FAILED after {task.retry_count} retries: {task_id} — {error}",
                         task_id=task_id)

        return task

    def request_human_review(self, task_id: str, notes: str, requesting_agent: str) -> None:
        task = self._get_task(task_id)
        task.status = TaskStatus.AWAITING_HUMAN
        task.human_review_requested = True
        task.human_review_notes = notes
        self.log.log(LogLevel.WARNING, requesting_agent,
                     f"Human review requested for task {task_id}: {notes}",
                     task_id=task_id)

    def should_retry(self, task_id: str) -> bool:
        task = self._get_task(task_id)
        return task.retry_count <= task.max_retries and task.status == TaskStatus.RETRYING

    # ─────────────────────────────────────────────
    # FORK MANAGEMENT
    # ─────────────────────────────────────────────

    def create_fork_set(
        self,
        parent_task_id: str,
        options: List[Dict[str, str]],
        current_fork_depth: int = 0,
    ) -> Optional[ForkSet]:
        """
        Create a ForkSet with one ForkPath per option.
        Returns None if fork depth/path limits exceeded (autonomous growth guard).
        """
        if current_fork_depth >= self.max_fork_depth:
            self.log.log(LogLevel.WARNING, self.state.instance_id,
                         f"Fork creation blocked: max depth {self.max_fork_depth} reached for task {parent_task_id}",
                         task_id=parent_task_id)
            return None

        if len(options) > self.max_fork_paths:
            self.log.log(LogLevel.WARNING, self.state.instance_id,
                         f"Fork creation truncated to {self.max_fork_paths} options (requested {len(options)})",
                         task_id=parent_task_id)
            options = options[:self.max_fork_paths]

        forkset = ForkSet(
            parent_task_id=parent_task_id,
            origin_option_count=len(options),
        )

        for option in options:
            fork = ForkPath(
                parent_task_id=parent_task_id,
                option_label=option.get("label", f"option-{uuid.uuid4().hex[:6]}"),
                option_description=option.get("description", ""),
                depth=current_fork_depth + 1,
                created_by=self.state.instance_id,
            )
            forkset.forks.append(fork)

        with self._lock:
            self.state.active_forks[forkset.forkset_id] = forkset

        self.log.log(LogLevel.INFO, self.state.instance_id,
                     f"ForkSet created: {forkset.forkset_id} with {len(forkset.forks)} paths for task {parent_task_id}",
                     task_id=parent_task_id)
        return forkset

    def mark_fork_tested(self, forkset_id: str, fork_id: str) -> None:
        """
        Mark a fork path as tested. When all forks in a set are tested,
        lock the set to prevent further autonomous growth.
        """
        forkset = self.state.active_forks.get(forkset_id)
        if not forkset:
            return

        for fork in forkset.forks:
            if fork.fork_id == fork_id:
                fork.test_completed = True
                fork.status = ForkStatus.COMPLETED
                if self.lock_forks_after_test:
                    fork.autonomy_locked = True
                    fork.status = ForkStatus.LOCKED

        # Check if ALL forks in set are tested
        if all(f.test_completed for f in forkset.forks):
            forkset.all_tested = True
            self.log.log(LogLevel.INFO, self.state.instance_id,
                         f"ForkSet fully tested and LOCKED: {forkset_id} — no further autonomous forking")

    def is_fork_growth_allowed(self, forkset_id: str) -> bool:
        """Return False if the forkset has been locked after testing."""
        forkset = self.state.active_forks.get(forkset_id)
        if not forkset:
            return True
        return not forkset.all_tested

    # ─────────────────────────────────────────────
    # QUERY
    # ─────────────────────────────────────────────

    def get_task(self, task_id: str) -> Optional[Task]:
        return self.state.active_tasks.get(task_id)

    def get_tasks_for_agent(self, agent_id: str) -> List[Task]:
        return [t for t in self.state.active_tasks.values() if t.assigned_to == agent_id]

    def get_pending_retries(self) -> List[Task]:
        return [t for t in self.state.active_tasks.values() if t.status == TaskStatus.RETRYING]

    def get_awaiting_human(self) -> List[Task]:
        return [t for t in self.state.active_tasks.values() if t.status == TaskStatus.AWAITING_HUMAN]

    def get_summary(self) -> Dict[str, Any]:
        status_counts: Dict[str, int] = {}
        for task in self.state.active_tasks.values():
            status_counts[task.status.value] = status_counts.get(task.status.value, 0) + 1
        return {
            "active_tasks": len(self.state.active_tasks),
            "completed_total": self.state.completed_task_count,
            "failed_total": self.state.failed_task_count,
            "active_forksets": len(self.state.active_forks),
            "status_breakdown": status_counts,
        }

    # ─────────────────────────────────────────────
    # INTERNAL
    # ─────────────────────────────────────────────

    def _get_task(self, task_id: str) -> Task:
        task = self.state.active_tasks.get(task_id)
        if not task:
            raise KeyError(f"Task not found: {task_id}")
        return task






