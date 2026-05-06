"""
FocalPoint-null Sub-Agents
Implementations for:
- AgentReview-00     : Reviews agent actions, suggests improvements, builds inter-agent awareness
- SecurityTriage-00  : Threat detection and sandboxed remediation
- QualityControl-00  : Code quality, refactoring, standards uplift
- StandardsGuard-00  : Standards management, schema updates, template and TODO management
"""

import json
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional
from uuid import uuid4

# Compatibility shim must run before agent_framework import
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
    AgentReviewReport,
    TaskStatus,
)


# ─────────────────────────────────────────────
# AGENT REVIEW — AgentReview-00
# ─────────────────────────────────────────────

class AgentReviewExecutor(Executor):
    """
    Reviews agent actions and task outcomes.
    Suggests new subagent roles, reduces regression and conflicts,
    builds inter-agent awareness for interoperability.
    Produces structured review reports for FocalPoint-null.
    """

    AGENT_ID = "AgentReview-00"
    agent: ChatAgent

    SYSTEM_PROMPT = """You are AgentReview-00, the agent review specialist in the FocalPoint-null system.

Your responsibilities:
1. PERFORMANCE REVIEW: Analyse task outcomes and agent actions provided to you.
2. REGRESSION DETECTION: Identify recurring failures, declining performance or conflicts between agents.
3. ROLE SUGGESTION: Recommend new agent roles or changes to existing agents when patterns indicate gaps.
4. INTEROPERABILITY: Map inter-agent dependencies and flag coordination issues.
5. REPORTING: Always respond with a structured JSON report.

Your output MUST be a JSON object:
{
  "reviewed_agent": "<agent_id>",
  "performance_score": 0.0-1.0,
  "issues_found": ["..."],
  "regressions_detected": ["..."],
  "improvement_suggestions": ["..."],
  "new_role_suggestions": ["..."],
  "interop_notes": ["..."]
}
Do NOT include code. Do NOT make changes directly. Only produce reports.
"""

    def __init__(self, client: Any, log: LogManager, id: str = AGENT_ID):
        self.log = log
        self.agent = client.create_agent(name=self.AGENT_ID, instructions=self.SYSTEM_PROMPT)
        super().__init__(id=id)

    @handler
    async def review(
        self, message: ChatMessage, ctx: WorkflowContext[Never, str]
    ) -> None:
        response = await self.agent.run([message])
        output = response.text or ""

        self.log.log_prompt(self.AGENT_ID, message.text or "", output)

        # Parse report
        report = self._parse_report(output)
        self.log.log(LogLevel.INFO, self.AGENT_ID,
                     f"Review complete for {report.get('reviewed_agent', '?')} "
                     f"score={report.get('performance_score', '?')}")

        await ctx.yield_output(json.dumps(report, indent=2))

    def _parse_report(self, text: str) -> Dict[str, Any]:
        start = text.find("{")
        end = text.rfind("}") + 1
        if start >= 0 and end > start:
            try:
                return json.loads(text[start:end])
            except Exception:
                pass
        return {"reviewed_agent": "?", "raw": text}


# ─────────────────────────────────────────────
# SECURITY TRIAGE — SecurityTriage-00
# ─────────────────────────────────────────────

class SecurityTriageExecutor(Executor):
    """
    Security detection and remediation agent.
    - Operates in sandboxed context (never output raw code directly).
    - All results must pass through ViewPoint-init before reaching FocalPoint.
    - Requires client simulation test before results are considered complete.
    """

    AGENT_ID = "SecurityTriage-00"
    agent: ChatAgent

    SYSTEM_PROMPT = """You are SecurityTriage-00, the security detection and remediation specialist.

IMPORTANT CONSTRAINTS:
- You operate in a SANDBOXED environment. Never output executable code directly.
- All your findings must be described as structured JSON assessments, not runnable scripts.
- Your output will pass through ViewPoint-init encoding before reaching FocalPoint.
- A virtual client proxy simulation must validate your remediation plan before it is accepted.

Your responsibilities:
1. THREAT DETECTION: Identify security threats, vulnerabilities, suspicious patterns.
2. ASSESSMENT: Score risk level and describe impact.
3. REMEDIATION PLAN: Describe remediation steps in plain structured form (not executable code).
4. SIMULATION NOTE: Mark whether your plan requires client simulation testing.

Output format:
{
  "threat_id": "<uuid>",
  "severity": "CRITICAL|HIGH|MEDIUM|LOW|INFO",
  "threat_type": "<type>",
  "description": "<description>",
  "affected_components": ["..."],
  "risk_score": 0.0-10.0,
  "remediation_plan": [{"step": 1, "description": "..."}],
  "requires_simulation": true,
  "sandbox_validated": false,
  "notes": "..."
}
"""

    def __init__(self, client: Any, log: LogManager, id: str = AGENT_ID):
        self.log = log
        self.agent = client.create_agent(name=self.AGENT_ID, instructions=self.SYSTEM_PROMPT)
        super().__init__(id=id)

    @handler
    async def triage(
        self, message: ChatMessage, ctx: WorkflowContext[Never, dict]
    ) -> None:
        response = await self.agent.run([message])
        output = response.text or ""

        self.log.log_prompt(self.AGENT_ID, message.text or "", output,
                            extra={"note": "security_triage_output_unvalidated"})

        # Parse assessment
        assessment = self._parse_assessment(output)

        # Flag: not yet sandbox validated (requires ViewPoint + client sim)
        assessment["sandbox_validated"] = False
        assessment["viewpoint_pending"] = True

        self.log.log(LogLevel.SECURITY, self.AGENT_ID,
                     f"Triage assessment: severity={assessment.get('severity','?')} "
                     f"risk={assessment.get('risk_score','?')} — awaiting ViewPoint encoding")

        await ctx.yield_output(assessment)

    def _parse_assessment(self, text: str) -> Dict[str, Any]:
        start = text.find("{")
        end = text.rfind("}") + 1
        if start >= 0 and end > start:
            try:
                return json.loads(text[start:end])
            except Exception:
                pass
        return {"severity": "UNKNOWN", "raw_output": text, "threat_id": str(uuid4())}


# ─────────────────────────────────────────────
# QUALITY CONTROL — QualityControl-00
# ─────────────────────────────────────────────

class QualityControlExecutor(Executor):
    """
    Code quality, refactoring and standards uplift agent.
    IMPORTANT: May only perform code operations if the target code has completed
    at least 1 full orchestration loop (version_loops_completed >= MIN_VERSION_LOOPS_FOR_CODE_OPS).
    """

    AGENT_ID = "QualityControl-00"
    agent: ChatAgent

    SYSTEM_PROMPT = """You are QualityControl-00, the code quality and standards specialist.

IMPORTANT CONSTRAINTS:
- You may only review, refactor or uplift code that has completed at least one full orchestration loop.
- Do NOT modify code that has never been through the orchestration review cycle.
- Maintain interoperational dependencies when making changes.

Your responsibilities:
1. CODE REVIEW: Review code quality, identify issues and suggest improvements.
2. REFACTORING: Describe refactoring changes in structured form.
3. STANDARDS UPLIFT: Ensure code meets current standards (see config/standards/).
4. DEPENDENCY ANALYSIS: Map and flag interoperational dependencies before making changes.

Output format:
{
  "target_file": "<file_path>",
  "quality_score": 0.0-1.0,
  "issues_found": [{"severity": "...", "line": 0, "description": "..."}],
  "refactoring_suggestions": [{"description": "...", "impact": "..."}],
  "standards_violations": ["..."],
  "dependency_notes": ["..."],
  "can_proceed_with_changes": true|false,
  "reasoning": "..."
}
"""

    def __init__(self, client: Any, log: LogManager,
                 min_version_loops: int = 1, id: str = AGENT_ID):
        self.log = log
        self.min_version_loops = min_version_loops
        self.agent = client.create_agent(name=self.AGENT_ID, instructions=self.SYSTEM_PROMPT)
        super().__init__(id=id)

    @handler
    async def review_quality(
        self, message: ChatMessage, ctx: WorkflowContext[Never, dict]
    ) -> None:
        response = await self.agent.run([message])
        output = response.text or ""

        self.log.log_prompt(self.AGENT_ID, message.text or "", output)

        result = self._parse_result(output)
        self.log.log(LogLevel.INFO, self.AGENT_ID,
                     f"Quality review complete: score={result.get('quality_score', '?')}")
        await ctx.yield_output(result)

    def _parse_result(self, text: str) -> Dict[str, Any]:
        start = text.find("{")
        end = text.rfind("}") + 1
        if start >= 0 and end > start:
            try:
                return json.loads(text[start:end])
            except Exception:
                pass
        return {"quality_score": 0.0, "raw": text}


# ─────────────────────────────────────────────
# STANDARDS GUARD — StandardsGuard-00
# ─────────────────────────────────────────────

class StandardsGuardExecutor(Executor):
    """
    Standards management, schema updates, template management and admin TO-DO recording.
    Completely separated from code changes to maintain independence.
    """

    AGENT_ID = "StandardsGuard-00"
    agent: ChatAgent

    SYSTEM_PROMPT = """You are StandardsGuard-00, the standards and template guardian.

Your responsibilities:
1. STANDARDS MANAGEMENT: Maintain the registry of standards and references.
2. SCHEMA UPDATES: Identify when schemas need updating and propose changes.
3. TEMPLATE MANAGEMENT: Ensure templates are current and categorised.
4. TO-DO RECORDING: Record admin TO-DO items with categories and priorities.
5. SOURCE REFERENCES: Maintain references to standards sources.

You MUST NOT modify code files. You manage standards documents, templates and TO-DO lists only.

Output format:
{
  "action": "update_standard" | "add_template" | "record_todo" | "schema_review",
  "standard_name": "...",
  "description": "...",
  "source_reference": "...",
  "todo_item": {
    "category": "new_agents|agent_changes|human_oversight_required|standards_updates|security_recommendations",
    "title": "...",
    "description": "...",
    "priority": "LOW|MEDIUM|HIGH|CRITICAL"
  },
  "reasoning": "..."
}
"""

    def __init__(self, client: Any, log: LogManager,
                 todo_dir: str = "todo", id: str = AGENT_ID):
        self.log = log
        self.todo_dir = todo_dir
        import pathlib
        pathlib.Path(todo_dir).mkdir(parents=True, exist_ok=True)
        self.agent = client.create_agent(name=self.AGENT_ID, instructions=self.SYSTEM_PROMPT)
        super().__init__(id=id)

    @handler
    async def manage_standards(
        self, message: ChatMessage, ctx: WorkflowContext[Never, dict]
    ) -> None:
        response = await self.agent.run([message])
        output = response.text or ""

        self.log.log_prompt(self.AGENT_ID, message.text or "", output)

        result = self._parse_result(output)
        action = result.get("action", "")

        if action == "record_todo" and result.get("todo_item"):
            self._persist_todo(result["todo_item"])

        self.log.log(LogLevel.INFO, self.AGENT_ID,
                     f"Standards action: {action}")
        await ctx.yield_output(result)

    def _persist_todo(self, todo_data: Dict[str, Any]) -> None:
        """Write a TODO item to the admin todo directory."""
        import pathlib
        item = AdminTodoItem(
            category=todo_data.get("category", "standards_updates"),
            title=todo_data.get("title", "Standards Update"),
            description=todo_data.get("description", ""),
            suggested_by=self.AGENT_ID,
            priority=todo_data.get("priority", "MEDIUM"),
        )
        path = pathlib.Path(self.todo_dir) / f"todo-standards-{item.todo_id[:8]}.json"
        path.write_text(item.model_dump_json(indent=2), encoding="utf-8")
        self.log.log(LogLevel.INFO, self.AGENT_ID,
                     f"Admin TODO recorded: [{item.category}] {item.title}")

    def _parse_result(self, text: str) -> Dict[str, Any]:
        start = text.find("{")
        end = text.rfind("}") + 1
        if start >= 0 and end > start:
            try:
                return json.loads(text[start:end])
            except Exception:
                pass
        return {"action": "unknown", "raw": text}
