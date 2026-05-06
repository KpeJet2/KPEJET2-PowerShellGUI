# VersionTag: 2605.B2.V31.7
# VersionTag: 2605.B2.V31.7
# VersionTag: 2605.B2.V31.7
# VersionTag: 2605.B2.V31.7
"""
Code Sin Registry
Persistent memory of all code sins (defects/failures) and their fixes.
Used by Code-B-iSmuth and Code-B-Tsted to remember, avoid, and resolve past problems.

Key behaviours:
- Every detected problem is logged as a CodeSin with a detection hash for rapid redetection.
- Problems with no fix commence root cause analysis automatically.
- Fixes are PILOT until applied successfully in >= TRUSTED_THRESHOLD (default 4) cases.
- Trusted fixes are propagated to all agents via the registry.
- Regression counts track how many times a resolved problem reappeared.
- Additional failure counts track side-effects introduced by fixes.
"""
from __future__ import annotations

import hashlib
import json
import os
import pathlib
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional

from core.models import (
    CodeFix,
    CodeSin,
    FixStatus,
    SinCategory,
    SinSeverity,
)
from core.log_manager import LogManager, LogLevel


TRUSTED_THRESHOLD = 4   # Applications to promote a fix from PILOT to TRUSTED


class SinRegistry:
    """
    Persistent registry of all code sins and fixes, stored as JSON files in
    sin_registry/ directory. Provides rapid detection via SHA256 detection hashes.
    """

    def __init__(self, registry_dir: str = "sin_registry", log: Optional[LogManager] = None):
        self.registry_dir = pathlib.Path(registry_dir)
        self.registry_dir.mkdir(parents=True, exist_ok=True)
        (self.registry_dir / "fixes").mkdir(exist_ok=True)
        self.log = log
        self._sins: Dict[str, CodeSin] = {}
        self._fixes: Dict[str, CodeFix] = {}
        self._detection_index: Dict[str, str] = {}  # detection_hash -> sin_id
        self._load_all()

    # ─────────────────────────────────────────────
    # PUBLIC: SIN REGISTRATION
    # ─────────────────────────────────────────────

    def record_sin(
        self,
        title: str,
        description: str,
        agent_id: str,
        reported_by: str,
        severity: SinSeverity = SinSeverity.MEDIUM,
        category: SinCategory = SinCategory.OTHER,
        file_path: Optional[str] = None,
        line_number: Optional[int] = None,
        function_name: Optional[str] = None,
        detection_method: str = "",
        root_cause: Optional[str] = None,
        is_security_related: bool = False,
        is_version_related: bool = False,
        is_access_violation: bool = False,
        is_untrapped_error: bool = False,
        task_id: Optional[str] = None,
    ) -> CodeSin:
        """
        Record a new code sin — or increment occurrence count if it was seen before
        (matched by detection hash). Returns the CodeSin.
        """
        detection_hash = self._compute_detection_hash(title, category, file_path, agent_id)

        # Check for existing sin by hash
        if detection_hash in self._detection_index:
            return self._increment_occurrence(
                self._detection_index[detection_hash],
                file_path=file_path,
                task_id=task_id,
                reported_by=reported_by,
            )

        sin = CodeSin(
            title=title,
            description=description,
            severity=severity,
            category=category,
            file_path=file_path,
            line_number=line_number,
            function_name=function_name,
            agent_id=agent_id,
            reported_by=reported_by,
            detection_method=detection_method,
            detection_hash=detection_hash,
            root_cause=root_cause,
            is_security_related=is_security_related,
            is_version_related=is_version_related,
            is_access_violation=is_access_violation,
            is_untrapped_error=is_untrapped_error,
            task_ids=[task_id] if task_id else [],
            location_history=[file_path] if file_path else [],
            reviewed_by_agents=[reported_by],
        )

        self._sins[sin.sin_id] = sin
        self._detection_index[detection_hash] = sin.sin_id
        self._persist_sin(sin)

        if self.log:
            self.log.log(
                LogLevel.WARNING, "SinRegistry",
                f"New sin recorded [{sin.severity}/{sin.category}]: {sin.title} "
                f"(agent={agent_id}, hash={detection_hash[:12]}...)",
                task_id=task_id,
            )

        return sin

    def record_regression(self, sin_id: str, task_id: Optional[str] = None) -> Optional[CodeSin]:
        """Mark a sin as regressed — it was resolved but reappeared."""
        sin = self._sins.get(sin_id)
        if sin:
            sin.regression_count += 1
            sin.is_resolved = False
            sin.resolved_at = None
            sin.last_seen_at = datetime.now(timezone.utc)
            if task_id and task_id not in sin.task_ids:
                sin.task_ids.append(task_id)
            self._persist_sin(sin)
            if self.log:
                self.log.log(LogLevel.WARNING, "SinRegistry",
                             f"Regression detected: sin {sin_id[:8]} ({sin.title}) — "
                             f"regression #{sin.regression_count}")
        return sin

    # ─────────────────────────────────────────────
    # PUBLIC: FIX MANAGEMENT
    # ─────────────────────────────────────────────

    def propose_fix(
        self,
        sin_id: str,
        description: str,
        fix_diff_summary: str,
        created_by: str,
        known_introduced_failures: Optional[List[str]] = None,
    ) -> Optional[CodeFix]:
        """Propose a pilot fix for a known sin."""
        sin = self._sins.get(sin_id)
        if not sin:
            return None

        fix = CodeFix(
            sin_id=sin_id,
            description=description,
            fix_diff_summary=fix_diff_summary,
            fix_status=FixStatus.PILOT,
            known_introduced_failures=known_introduced_failures or [],
            additional_failures_count=len(known_introduced_failures or []),
            created_by=created_by,
            pilot_milestone_at=datetime.now(timezone.utc),
            # Detection hash mirrors the sin for rapid cross-agent lookups
            detection_hash=sin.detection_hash,
        )

        self._fixes[fix.fix_id] = fix
        sin.fix_id = fix.fix_id
        sin.fix_status = FixStatus.PILOT
        self._persist_fix(fix)
        self._persist_sin(sin)

        if self.log:
            self.log.log(LogLevel.INFO, "SinRegistry",
                         f"Fix proposed (PILOT) for sin {sin_id[:8]}: {description[:60]}")

        return fix

    def apply_fix(self, fix_id: str, task_id: str, success: bool) -> Optional[CodeFix]:
        """
        Record a fix application. If success and applied_count reaches threshold → TRUSTED.
        Logs side-effect failures to be tracked as new sins.
        """
        fix = self._fixes.get(fix_id)
        if not fix:
            return None

        if success:
            fix.applied_count += 1
            fix.applied_cases.append(task_id)

            if (fix.fix_status == FixStatus.PILOT
                    and fix.applied_count >= fix.trusted_threshold):
                fix.fix_status = FixStatus.TRUSTED
                fix.trusted_at = datetime.now(timezone.utc)
                fix.trusted_milestone_at = datetime.now(timezone.utc)

                # Update the parent sin
                sin = self._sins.get(fix.sin_id)
                if sin:
                    sin.fix_status = FixStatus.TRUSTED
                    sin.is_resolved = True
                    sin.resolved_at = datetime.now(timezone.utc)
                    self._persist_sin(sin)

                if self.log:
                    self.log.log(LogLevel.INFO, "SinRegistry",
                                 f"Fix {fix_id[:8]} promoted to TRUSTED after "
                                 f"{fix.applied_count} successful applications. "
                                 f"Milestone: all agents must honour this fix.")

            self._persist_fix(fix)

        else:
            # Failed application — do not revoke automatically, but note it
            if self.log:
                self.log.log(LogLevel.WARNING, "SinRegistry",
                             f"Fix {fix_id[:8]} application FAILED in task {task_id}. "
                             f"Total successful: {fix.applied_count}. Consider revision.")

        return fix

    def revoke_fix(self, fix_id: str, reason: str) -> Optional[CodeFix]:
        """Revoke a fix that has itself become a problem."""
        fix = self._fixes.get(fix_id)
        if fix:
            fix.fix_status = FixStatus.REVOKED
            self._persist_fix(fix)
            sin = self._sins.get(fix.sin_id)
            if sin:
                sin.fix_status = FixStatus.PENDING
                sin.is_resolved = False
                self._persist_sin(sin)
            if self.log:
                self.log.log(LogLevel.ERROR, "SinRegistry",
                             f"Fix {fix_id[:8]} REVOKED: {reason}")
        return fix

    # ─────────────────────────────────────────────
    # PUBLIC: QUERIES
    # ─────────────────────────────────────────────

    def detect_by_hash(self, title: str, category: SinCategory,
                       file_path: Optional[str], agent_id: str) -> Optional[CodeSin]:
        """Rapid detection: compute hash and look it up instantly."""
        h = self._compute_detection_hash(title, category, file_path, agent_id)
        sin_id = self._detection_index.get(h)
        return self._sins.get(sin_id) if sin_id else None

    def get_trusted_fixes(self) -> List[CodeFix]:
        return [f for f in self._fixes.values() if f.fix_status == FixStatus.TRUSTED]

    def get_sins_for_agent(self, agent_id: str) -> List[CodeSin]:
        return [s for s in self._sins.values() if s.agent_id == agent_id]

    def get_unresolved_sins(self) -> List[CodeSin]:
        return [s for s in self._sins.values() if not s.is_resolved]

    def get_sins_needing_fix(self) -> List[CodeSin]:
        return [s for s in self._sins.values()
                if not s.is_resolved and s.fix_status == FixStatus.PENDING]

    def get_summary(self) -> Dict[str, Any]:
        total_sins = len(self._sins)
        resolved = sum(1 for s in self._sins.values() if s.is_resolved)
        total_fixes = len(self._fixes)
        trusted = sum(1 for f in self._fixes.values() if f.fix_status == FixStatus.TRUSTED)
        pilot = sum(1 for f in self._fixes.values() if f.fix_status == FixStatus.PILOT)
        regression_total = sum(s.regression_count for s in self._sins.values())
        sin_by_category: Dict[str, int] = {}
        for s in self._sins.values():
            sin_by_category[s.category] = sin_by_category.get(s.category, 0) + 1
        return {
            "total_sins": total_sins,
            "resolved_sins": resolved,
            "unresolved_sins": total_sins - resolved,
            "total_fixes": total_fixes,
            "trusted_fixes": trusted,
            "pilot_fixes": pilot,
            "total_regressions": regression_total,
            "sins_by_category": sin_by_category,
            "detection_index_size": len(self._detection_index),
        }

    # ─────────────────────────────────────────────
    # INTERNAL HELPERS
    # ─────────────────────────────────────────────

    @staticmethod
    def _compute_detection_hash(
        title: str,
        category: Any,
        file_path: Optional[str],
        agent_id: str,
    ) -> str:
        """Deterministic SHA256 hash for rapid sin redetection."""
        key = f"{title.lower().strip()}|{str(category)}|{file_path or ''}|{agent_id}"
        return hashlib.sha256(key.encode("utf-8")).hexdigest()

    def _increment_occurrence(
        self, sin_id: str, file_path: Optional[str], task_id: Optional[str], reported_by: str
    ) -> CodeSin:
        sin = self._sins[sin_id]
        sin.occurrence_count += 1
        sin.last_seen_at = datetime.now(timezone.utc)
        if file_path and file_path not in sin.location_history:
            sin.location_history.append(file_path)
        if task_id and task_id not in sin.task_ids:
            sin.task_ids.append(task_id)
        if reported_by not in sin.reviewed_by_agents:
            sin.reviewed_by_agents.append(reported_by)
        # If previously resolved, count as regression
        if sin.is_resolved:
            sin.regression_count += 1
            sin.is_resolved = False
        self._persist_sin(sin)
        if self.log:
            self.log.log(LogLevel.WARNING, "SinRegistry",
                         f"Known sin recurred ({sin.occurrence_count}x): {sin.title[:60]} "
                         f"(sin_id={sin_id[:8]}...)")
        return sin

    def _persist_sin(self, sin: CodeSin) -> None:
        path = self.registry_dir / f"sin-{sin.sin_id}.json"
        path.write_text(sin.model_dump_json(indent=2), encoding="utf-8")

    def _persist_fix(self, fix: CodeFix) -> None:
        path = self.registry_dir / "fixes" / f"fix-{fix.fix_id}.json"
        path.write_text(fix.model_dump_json(indent=2), encoding="utf-8")

    def _load_all(self) -> None:
        """Load all persisted sins and fixes from disk on startup."""
        for path in self.registry_dir.glob("sin-*.json"):
            try:
                sin = CodeSin.model_validate_json(path.read_text(encoding="utf-8"))
                self._sins[sin.sin_id] = sin
                if sin.detection_hash:
                    self._detection_index[sin.detection_hash] = sin.sin_id
            except Exception:
                pass

        for path in (self.registry_dir / "fixes").glob("fix-*.json"):
            try:
                fix = CodeFix.model_validate_json(path.read_text(encoding="utf-8"))
                self._fixes[fix.fix_id] = fix
            except Exception:
                pass







