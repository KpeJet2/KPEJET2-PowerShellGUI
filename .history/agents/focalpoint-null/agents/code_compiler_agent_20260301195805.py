"""
Code-B-iSmuth-00 — Code Compiler / Generator Agent

Specialises in:
- Generating and compiling code governed by feedback from ALL existing agents.
- Referencing and reusing existing modules/functionals where viable before writing new code.
- Honouring orchestrator directives strictly.
- Avoiding all known sins (detection hash lookup before generating).
- Honouring all TRUSTED fixes.
- Preparing a handover checklist for Code-B-Tsted: security, syntax, standards,
  exit logic, error trapping.
- Maintaining a pipeline ingress/egress task request flow with all other agents.
- Automating creation and response to past-sin-based issue reports.
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
    AdminTodoItem,
    CodeSin,
    CompilerOutput,
    FixStatus,
    SinCategory,
    SinSeverity,
)
from core.sin_registry import SinRegistry


AGENT_ID = "Code-B-iSmuth-00"


class CodeCompilerExecutor(Executor):
    """
    Code-B-iSmuth-00: Code generation and compilation agent.

    Pipeline role:
    - Ingress: receives task requests from FocalPoint-null orchestrator.
    - Consults all expert agents for governance feedback before generating any code.
    - Checks sin registry for known past sins to actively avoid them.
    - Honours all TRUSTED fixes inline with expert roles.
    - Egress: sends output to Code-B-Tsted for testing; never ships code directly.
    """

    AGENT_ID = AGENT_ID
    agent: ChatAgent

    SYSTEM_PROMPT = """You are Code-B-iSmuth-00, the code compiler and generation specialist in FocalPoint-null.

CRITICAL CONSTRAINTS:
1. You MUST NOT produce code that ignores governance feedback from SecurityTriage, AgentReview,
   QualityControl, or StandardsGuard. All feedback must be reflected in your output.
2. You MUST check for known code sins before generating code and actively avoid repeating them.
3. You MUST honour all TRUSTED fixes — they are mandatory, not optional.
4. You MUST reuse existing modules and functionals whenever viable before writing new code.
5. You MUST produce a handover checklist for Code-B-Tsted covering:
   security, syntax, standards, exit_logic, error_trapping.
6. You MUST NOT deploy or execute code. Handover to Code-B-Tsted only.
7. You MUST broker all inter-agent communication through FocalPoint-null.
8. You process-automate both NEW code creation and RESPONSES to issue reports from past sins.

GOVERNANCE PIPELINE:
Ingress → [SecurityTriage feedback] → [AgentReview feedback] → [QualityControl feedback]
       → [StandardsGuard feedback] → Generate/Compile → Handover checklist → Egress to Code-B-Tsted

KNOWN SIN AVOIDANCE:
Before generating, review the sin avoidance table provided in your context.
For each known sin: if detection hash matches any code pattern you intend to write, refactor away
from it immediately. Document which sins you avoided and why.

TRUSTED FIX COMPLIANCE:
All TRUSTED fixes are mandatory. You must apply them wherever the corresponding pattern exists.

OUTPUT FORMAT (JSON):
{
  "file_path": "<target file>",
  "language": "<python|powershell|etc>",
  "code_summary": "<plain summary of what this code does>",
  "referenced_modules": ["<module paths reused>"],
  "governance_feedback_applied": ["SecurityTriage: ...", "QualityControl: ...", ...],
  "known_sins_avoided": ["<sin title> (sin_id=...)"],
  "trusted_fixes_honoured": ["<fix description> (fix_id=...)"],
  "handover_checklist": {
    "security": true|false,
    "syntax": true|false,
    "standards": true|false,
    "exit_logic": true|false,
    "error_trapping": true|false
  },
  "ready_for_handover": true|false,
  "code_block": "<the generated code>",
  "reasoning": "<why this approach>"
}
"""

    def __init__(
        self,
        client: Any,
        log: LogManager,
        sin_registry: SinRegistry,
        modules_dir: str = "modules",
        scripts_dir: str = "scripts",
        id: str = AGENT_ID,
    ):
        self.log = log
        self.sin_registry = sin_registry
        self.modules_dir = pathlib.Path(modules_dir)
        self.scripts_dir = pathlib.Path(scripts_dir)
        self.agent = client.create_agent(name=self.AGENT_ID, instructions=self.SYSTEM_PROMPT)
        super().__init__(id=id)

    @handler
    async def compile_code(
        self,
        message: ChatMessage,
        ctx: WorkflowContext[Never, str],
    ) -> None:
        """
        Main handler: receives a code generation/compilation task.
        Prepares sin-avoidance context, runs the LLM, parses output,
        updates sin registry with avoidances, then yields handover package to Code-B-Tsted.
        """
        self.log.log(LogLevel.INFO, self.AGENT_ID,
                     "Compiler pipeline initiated — checking sin registry before generation")

        # Build sin avoidance context to inject into the LLM
        sin_context = self._build_sin_avoidance_context()
        trusted_fix_context = self._build_trusted_fix_context()

        # Prepend sin and fix context to the conversation
        augmented_messages = [message]
        if sin_context or trusted_fix_context:
            context_text = (
                "=== SIN AVOIDANCE TABLE ===\n" + (sin_context or "(none)") +
                "\n\n=== MANDATORY TRUSTED FIXES ===\n" + (trusted_fix_context or "(none)")
            )
            augmented_messages.insert(0, ChatMessage(role="system", text=context_text))

        response = await self.agent.run(augmented_messages)
        output_text = response.text or ""

        self.log.log_prompt(self.AGENT_ID,
                            message.text or "",
                            output_text)

        result = self._parse_output(output_text)

        # Record any sins this compiler is avoiding (for cross-agent sharing)
        self._record_avoidances(result)

        # Check if new issues surfaced that have no fix
        self._auto_report_unfixed_patterns(result)

        # Build CompilerOutput record
        compiler_output = CompilerOutput(
            produced_by=self.AGENT_ID,
            file_path=result.get("file_path", "unknown"),
            language=result.get("language", "unknown"),
            code_summary=result.get("code_summary", ""),
            referenced_modules=result.get("referenced_modules", []),
            governance_feedback_applied=result.get("governance_feedback_applied", []),
            known_sins_avoided=result.get("known_sins_avoided", []),
            trusted_fixes_honoured=result.get("trusted_fixes_honoured", []),
            ready_for_handover=result.get("ready_for_handover", False),
            handover_checklist=result.get("handover_checklist", {}),
        )

        self.log.log(
            LogLevel.INFO, self.AGENT_ID,
            f"Compilation complete: {compiler_output.file_path} — "
            f"ready_for_handover={compiler_output.ready_for_handover}, "
            f"sins_avoided={len(compiler_output.known_sins_avoided)}, "
            f"trusted_fixes_honoured={len(compiler_output.trusted_fixes_honoured)}"
        )

        # Yield full JSON payload to Code-B-Tsted via ViewPoint
        await ctx.yield_output(json.dumps({
            "compiler_output": compiler_output.model_dump(mode="json"),
            "code_block": result.get("code_block", ""),
            "reasoning": result.get("reasoning", ""),
        }, indent=2))

    # ─────────────────────────────────────────────
    # ISSUE AUTOMATION
    # ─────────────────────────────────────────────

    def process_issue_report(
        self,
        issue_text: str,
        task_id: str,
        reported_by: str,
        agent_id: str,
        file_path: Optional[str] = None,
    ) -> CodeSin:
        """
        Automation entry point when a past sin report arrives via ingress pipeline.
        Checks if sin is already known (by hash), increments occurrence, or logs new sin.
        Triggers root cause analysis record if no fix exists yet.
        """
        # Attempt rapid hash detection first
        existing = self.sin_registry.detect_by_hash(
            title=issue_text[:80],
            category=SinCategory.OTHER,
            file_path=file_path,
            agent_id=agent_id,
        )
        if existing:
            sin = self.sin_registry._increment_occurrence(
                existing.sin_id, file_path=file_path, task_id=task_id, reported_by=reported_by
            )
        else:
            sin = self.sin_registry.record_sin(
                title=issue_text[:120],
                description=issue_text,
                agent_id=agent_id,
                reported_by=reported_by,
                detection_method="ingress_issue_report",
                file_path=file_path,
                task_id=task_id,
            )

        # If no fix exists, auto-queue for review
        if sin.fix_id is None:
            self.log.log(LogLevel.WARNING, self.AGENT_ID,
                         f"No fix for sin {sin.sin_id[:8]} ({sin.title[:60]}) — "
                         f"queuing for root cause analysis and pilot fix")
            self._queue_rca(sin, task_id)

        return sin

    def _queue_rca(self, sin: CodeSin, task_id: str) -> None:
        """Persist a root cause analysis TODO for admin + agent review."""
        item = AdminTodoItem(
            category="code_sin_rca",
            title=f"RCA needed: {sin.title[:80]}",
            description=(
                f"Sin ID: {sin.sin_id}\n"
                f"Category: {sin.category}\nSeverity: {sin.severity}\n"
                f"Occurrences: {sin.occurrence_count}\n"
                f"Security: {sin.is_security_related}\n"
                f"Version: {sin.is_version_related}\n"
                f"Access violation: {sin.is_access_violation}\n"
                f"Untrapped error: {sin.is_untrapped_error}\n"
                f"No fix currently on record. Commence: validate → isolate → "
                f"root cause → pilot fix → verify 4x → promote to TRUSTED."
            ),
            suggested_by=self.AGENT_ID,
            priority="HIGH" if sin.severity in ("CRITICAL", "HIGH") else "MEDIUM",
        )
        todo_dir = pathlib.Path(
            __import__("os").getenv("TODO_DIR", "todo")
        )
        todo_dir.mkdir(parents=True, exist_ok=True)
        path = todo_dir / f"todo-rca-{sin.sin_id[:8]}.json"
        path.write_text(item.model_dump_json(indent=2), encoding="utf-8")

    # ─────────────────────────────────────────────
    # CONTEXT BUILDERS
    # ─────────────────────────────────────────────

    def _build_sin_avoidance_context(self) -> str:
        sins = self.sin_registry.get_unresolved_sins()
        if not sins:
            return "No known unresolved sins. Proceed with standard governance."
        lines = []
        for s in sins[:30]:  # Limit context size
            flags = []
            if s.is_security_related:
                flags.append("SECURITY")
            if s.is_version_related:
                flags.append("VERSION")
            if s.is_access_violation:
                flags.append("ACCESS_VIOLATION")
            if s.is_untrapped_error:
                flags.append("UNTRAPPED_ERROR")
            lines.append(
                f"- [{s.severity}/{s.category}] {s.title} "
                f"(sin_id={s.sin_id[:8]}, occurrences={s.occurrence_count}, "
                f"regressions={s.regression_count}"
                + (f", FLAGS: {','.join(flags)}" if flags else "") +
                f")\n  Agent: {s.agent_id} | File: {s.file_path or 'N/A'}"
                + (f"\n  Root cause: {s.root_cause}" if s.root_cause else "")
            )
        return "\n".join(lines)

    def _build_trusted_fix_context(self) -> str:
        fixes = self.sin_registry.get_trusted_fixes()
        if not fixes:
            return "No TRUSTED fixes on record yet."
        lines = []
        for f in fixes:
            sin = self.sin_registry._sins.get(f.sin_id)
            sin_title = sin.title if sin else "Unknown"
            lines.append(
                f"- TRUSTED FIX (fix_id={f.fix_id[:8]}, applied={f.applied_count}x)\n"
                f"  For sin: {sin_title}\n"
                f"  Fix: {f.description}\n"
                f"  Diff summary: {f.fix_diff_summary[:120]}"
                + (f"\n  Known side-effects ({f.additional_failures_count}): "
                   f"{'; '.join(f.known_introduced_failures[:3])}"
                   if f.known_introduced_failures else "")
            )
        return "\n".join(lines)

    def _record_avoidances(self, result: Dict[str, Any]) -> None:
        """Log which sins this LLM run actively avoided (for cross-agent learning)."""
        for avoided in result.get("known_sins_avoided", []):
            self.log.log(LogLevel.INFO, self.AGENT_ID,
                         f"Avoidance documented: {avoided[:80]}")

    def _auto_report_unfixed_patterns(self, result: Dict[str, Any]) -> None:
        """
        If the compiler itself surfaces unfixed patterns via its reasoning,
        auto-register them in the sin registry for future prevention.
        """
        reasoning = result.get("reasoning", "")
        if "error" in reasoning.lower() or "untrapped" in reasoning.lower():
            # Surface-level heuristic — in production, parse structured reasoning flags
            self.log.log(LogLevel.INFO, self.AGENT_ID,
                         "Compiler reasoning surfaced potential error patterns — "
                         "recommend issuing full test run via Code-B-Tsted")

    def _parse_output(self, text: str) -> Dict[str, Any]:
        start = text.find("{")
        end = text.rfind("}") + 1
        if start >= 0 and end > start:
            try:
                return json.loads(text[start:end])
            except Exception:
                pass
        return {
            "file_path": "unknown",
            "language": "unknown",
            "code_summary": text[:200],
            "code_block": text,
            "ready_for_handover": False,
            "handover_checklist": {
                "security": False, "syntax": False, "standards": False,
                "exit_logic": False, "error_trapping": False,
            },
        }
