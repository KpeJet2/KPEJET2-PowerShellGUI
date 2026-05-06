"""
Code-B-Tsted-00 — Code Testing Agent

Specialises in:
- Unpacking, initialising, executing and tracing Code-B-iSmuth output.
- Running: security checks, syntax checks, standards checks, exit logic checks,
  error trapping checks, and full trace test runs.
- Reporting all findings back to FocalPoint-null (never to Code-B-iSmuth directly).
- Updating the sin registry with newly detected sins found during test.
- Applying and tracking trusted fix applications.
- NEVER creates or modifies code — test and report only.
- Obeys override directives exclusively from the lowest-ID FocalPoint-null in operation.
"""

import json
import pathlib
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional
from uuid import uuid4

import sys
sys.path.insert(0, str(__import__('pathlib').Path(__file__).parent.parent))
from compat import apply_patches
apply_patches()

from agent_framework import (
    ChatAgent,
    ChatMessage,
    Executor,
    WorkflowContext,
    handler,
)
from typing_extensions import Never

from core.log_manager import LogManager, LogLevel
from core.models import (
    CodeSinReport,
    FixStatus,
    SinCategory,
    SinSeverity,
)
from core.sin_registry import SinRegistry


AGENT_ID = "Code-B-Tsted-00"


class CodeTesterExecutor(Executor):
    """
    Code-B-Tsted-00: Code unpacking, execution, tracing and test reporting agent.

    Pipeline role:
    - Receives handover package from Code-B-iSmuth (via ViewPoint-init + FocalPoint brokering).
    - Validates handover checklist completeness before initiating test.
    - Executes test pipeline: security → syntax → standards → exit logic → error trapping.
    - Reports ALL findings to FocalPoint-null — both sins detected and fixes applied.
    - Updates sin registry: new sins, regressions, fix applications.
    - NEVER modifies code. Test and report only.
    - Override authority: lowest-ID FocalPoint-null in operation overrules all else.
    """

    AGENT_ID = AGENT_ID
    agent: ChatAgent

    SYSTEM_PROMPT = """You are Code-B-Tsted-00, the code testing and trace specialist in FocalPoint-null.

ABSOLUTE CONSTRAINTS:
1. You MUST NOT write, modify, or compile code. Your role is TESTING AND REPORTING ONLY.
2. You MUST report all findings to FocalPoint-null — never route results back to Code-B-iSmuth directly.
3. You MUST run ALL test categories on every handover: security, syntax, standards, exit_logic, error_trapping.
4. You MUST check the sin registry for known sins before reporting — identify if findings are new or known regressions.
5. You MUST apply TRUSTED fixes where they match test failures, then log the application.
6. You MUST track each sin with: when found, how many times, where, why it was made, security/version/access flags.
7. You HAVE override authority from the lowest-ID FocalPoint-null in operation ONLY.

TEST PIPELINE (in order):
1. UNPACK: Unpack and initialise the handover package from Code-B-iSmuth.
2. SYNTAX: Run syntax and parse checks.
3. SECURITY: Run security pattern checks (injection, hardcoded secrets, access violations, sandboxing).
4. STANDARDS: Validate against known standards (from StandardsGuard).
5. EXIT LOGIC: Verify all exit paths are handled — no orphaned exit conditions.
6. ERROR TRAPPING: Confirm all error states are trapped and logged — no unhandled exceptions.
7. TRACE: Execute a trace test run and capture all outputs and exceptions.
8. REPORT: Produce a structured CodeSinReport.

FOR EACH FINDING report:
- Is it security related? Version related? Access violation? Untrapped error?
- Was it seen before (known sin or new)?
- If known: how many times has it appeared before?
- If a TRUSTED fix exists and was applied: document it.
- How many additional failures might the fix introduce?
- How many regressions detected total?

OUTPUT FORMAT (JSON):
{
  "target_agent": "<agent whose code was tested>",
  "test_type": "full",
  "test_passed": true|false,
  "test_summary": "<1-3 sentence summary>",
  "sins_detected": [
    {
      "title": "...",
      "description": "...",
      "severity": "CRITICAL|HIGH|MEDIUM|LOW|INFO",
      "category": "SECURITY|VERSION|ACCESS_VIOLATION|UNTRAPPED_ERROR|LOGIC|STANDARDS|REGRESSION|SYNTAX|EXIT_LOGIC|DEPENDENCY|OTHER",
      "file_path": "...",
      "line_number": null,
      "function_name": null,
      "is_security_related": false,
      "is_version_related": false,
      "is_access_violation": false,
      "is_untrapped_error": false,
      "root_cause": "...",
      "is_known_sin": false,
      "sin_id": null,
      "trusted_fix_applied": null,
      "additional_failures_from_fix": 0
    }
  ],
  "trusted_fixes_applied": [{"fix_id": "...", "description": "..."}],
  "regressions_detected": 0,
  "new_sins_count": 0,
  "known_sins_recurred": 0,
  "trace_log": ["step 1: ...", "step 2: ..."],
  "recommendations": ["..."]
}
"""

    def __init__(
        self,
        client: Any,
        log: LogManager,
        sin_registry: SinRegistry,
        id: str = AGENT_ID,
    ):
        self.log = log
        self.sin_registry = sin_registry
        self.agent = client.create_agent(name=self.AGENT_ID, instructions=self.SYSTEM_PROMPT)
        super().__init__(id=id)

    @handler
    async def run_tests(
        self,
        messages: list[ChatMessage],
        ctx: WorkflowContext[Never, str],
    ) -> None:
        """
        Main handler: receives handover package (from Code-B-iSmuth via ViewPoint + FocalPoint).

        1. Injects sin registry context so LLM knows what to look for.
        2. Runs the full LLM-based test pipeline.
        3. Parses results and updates the sin registry.
        4. Yields a CodeSinReport JSON for FocalPoint-null.
        """
        self.log.log(LogLevel.INFO, self.AGENT_ID,
                     "Test pipeline starting — ingesting handover package")

        # Build context from sin registry (known sins + trusted fixes to apply)
        known_sins_context = self._build_known_sins_context()
        trusted_fix_context = self._build_trusted_fix_context()

        augmented = list(messages)
        if known_sins_context or trusted_fix_context:
            injection = (
                "=== KNOWN SIN DETECTION TABLE ===\n" + (known_sins_context or "(none)") +
                "\n\n=== TRUSTED FIXES TO APPLY ON MATCH ===\n" + (trusted_fix_context or "(none)")
            )
            augmented.insert(0, ChatMessage(role="system", text=injection))

        response = await self.agent.run(augmented)
        output_text = response.text or ""

        self.log.log_prompt(self.AGENT_ID,
                            "\n".join(m.text or "" for m in messages),
                            output_text)

        result = self._parse_result(output_text)

        # Update sin registry with findings
        report = self._process_findings(result)

        self.log.log(
            LogLevel.INFO, self.AGENT_ID,
            f"Test complete: passed={report.test_passed}, "
            f"new_sins={report.new_sins_count}, "
            f"regressions={report.regressions_detected}, "
            f"trusted_fixes_applied={report.trusted_fixes_applied}"
        )

        if not report.test_passed:
            self.log.log(LogLevel.WARNING, self.AGENT_ID,
                         f"HANDOVER REJECTED — test failed. "
                         f"Code-B-iSmuth must remediate {report.new_sins_count + report.known_sins_recurred} "
                         f"issue(s) before re-submission.")

        await ctx.yield_output(report.model_dump_json(indent=2))

    # ─────────────────────────────────────────────
    # SIN REGISTRY PROCESSING
    # ─────────────────────────────────────────────

    def _process_findings(self, result: Dict[str, Any]) -> CodeSinReport:
        """Update sin registry from test findings and build the CodeSinReport."""
        target_agent = result.get("target_agent", "unknown")
        sin_ids: List[str] = []
        new_sins = 0
        known_recurred = 0
        regressions = 0
        trusted_applied = result.get("trusted_fixes_applied", [])

        for finding in result.get("sins_detected", []):
            category = self._map_category(finding.get("category", "OTHER"))
            severity = self._map_severity(finding.get("severity", "MEDIUM"))

            existing = self.sin_registry.detect_by_hash(
                title=finding.get("title", "")[:80],
                category=category,
                file_path=finding.get("file_path"),
                agent_id=target_agent,
            )

            if existing:
                # Known sin — increment occurrence and check for regression
                updated = self.sin_registry.record_regression(
                    existing.sin_id,
                    task_id=result.get("task_id"),
                )
                sin_ids.append(existing.sin_id)
                known_recurred += 1
                if existing.is_resolved:
                    regressions += 1
                finding["sin_id"] = existing.sin_id
                finding["is_known_sin"] = True
            else:
                # New sin
                sin = self.sin_registry.record_sin(
                    title=finding.get("title", "Untitled finding")[:120],
                    description=finding.get("description", ""),
                    agent_id=target_agent,
                    reported_by=self.AGENT_ID,
                    severity=severity,
                    category=category,
                    file_path=finding.get("file_path"),
                    line_number=finding.get("line_number"),
                    function_name=finding.get("function_name"),
                    detection_method="code_b_tsted_test_pipeline",
                    root_cause=finding.get("root_cause"),
                    is_security_related=finding.get("is_security_related", False),
                    is_version_related=finding.get("is_version_related", False),
                    is_access_violation=finding.get("is_access_violation", False),
                    is_untrapped_error=finding.get("is_untrapped_error", False),
                )
                sin_ids.append(sin.sin_id)
                new_sins += 1
                finding["sin_id"] = sin.sin_id
                finding["is_known_sin"] = False

            # Apply trusted fix if the LLM flagged one
            fix_id = finding.get("trusted_fix_applied")
            if fix_id:
                self.sin_registry.apply_fix(
                    fix_id=fix_id,
                    task_id=result.get("task_id", str(uuid4())),
                    success=True,
                )

        # Apply fix records for any trusted fixes cited in the top-level list
        for fix_entry in trusted_applied:
            fid = fix_entry.get("fix_id")
            if fid:
                self.sin_registry.apply_fix(
                    fix_id=fid,
                    task_id=result.get("task_id", str(uuid4())),
                    success=True,
                )

        return CodeSinReport(
            produced_by=self.AGENT_ID,
            target_agent=target_agent,
            test_type=result.get("test_type", "full"),
            sins_detected=sin_ids,
            new_sins_count=new_sins,
            known_sins_recurred=known_recurred,
            trusted_fixes_applied=len(trusted_applied),
            pilot_fixes_applied=0,
            regressions_detected=regressions,
            test_passed=result.get("test_passed", False),
            test_summary=result.get("test_summary", ""),
            trace_log=result.get("trace_log", []),
            recommendations=result.get("recommendations", []),
        )

    # ─────────────────────────────────────────────
    # CONTEXT BUILDERS
    # ─────────────────────────────────────────────

    def _build_known_sins_context(self) -> str:
        sins = self.sin_registry.get_unresolved_sins()
        if not sins:
            return "No known unresolved sins on record."
        lines = []
        for s in sins[:30]:
            lines.append(
                f"- sin_id={s.sin_id[:8]} [{s.severity}/{s.category}] "
                f"'{s.title}' | occurrences={s.occurrence_count} | "
                f"regressions={s.regression_count} | "
                f"security={s.is_security_related} | "
                f"version={s.is_version_related} | "
                f"access_violation={s.is_access_violation} | "
                f"untrapped={s.is_untrapped_error} | "
                f"agent={s.agent_id} | file={s.file_path or 'N/A'}"
                + (f"\n  Root cause: {s.root_cause}" if s.root_cause else "")
                + (f"\n  Fix status: {s.fix_status}" if s.fix_status else "")
            )
        return "\n".join(lines)

    def _build_trusted_fix_context(self) -> str:
        fixes = self.sin_registry.get_trusted_fixes()
        if not fixes:
            return "No TRUSTED fixes available yet."
        lines = []
        for f in fixes:
            sin = self.sin_registry._sins.get(f.sin_id)
            sin_title = sin.title if sin else "Unknown"
            lines.append(
                f"- fix_id={f.fix_id[:8]} | For sin: '{sin_title}'\n"
                f"  Apply: {f.description}\n"
                f"  Change: {f.fix_diff_summary[:120]}\n"
                f"  Side-effects ({f.additional_failures_count}): "
                f"{'; '.join(f.known_introduced_failures[:3]) or 'none noted'}"
            )
        return "\n".join(lines)

    # ─────────────────────────────────────────────
    # HELPERS
    # ─────────────────────────────────────────────

    @staticmethod
    def _map_category(cat: str) -> SinCategory:
        try:
            return SinCategory(cat.upper())
        except ValueError:
            return SinCategory.OTHER

    @staticmethod
    def _map_severity(sev: str) -> SinSeverity:
        try:
            return SinSeverity(sev.upper())
        except ValueError:
            return SinSeverity.MEDIUM

    def _parse_result(self, text: str) -> Dict[str, Any]:
        start = text.find("{")
        end = text.rfind("}") + 1
        if start >= 0 and end > start:
            try:
                return json.loads(text[start:end])
            except Exception:
                pass
        return {
            "target_agent": "unknown",
            "test_type": "full",
            "test_passed": False,
            "test_summary": "Parse error — raw output stored in trace log.",
            "sins_detected": [],
            "trusted_fixes_applied": [],
            "regressions_detected": 0,
            "trace_log": [text[:500]],
            "recommendations": ["Re-submit with valid JSON from Code-B-iSmuth."],
        }
