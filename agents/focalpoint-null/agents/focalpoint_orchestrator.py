# VersionTag: 2605.B2.V31.7
"""
FocalPoint-null-00 — Root Orchestrator Agent
Primary directive: task allocation, role control, agent review, human review brokering,
organic growth suggestions, inter-agent PKI brokering, checkpoint management.
"""

import asyncio
import hashlib
import json
import os
import uuid
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional
from uuid import uuid4

# Compatibility shim must run before agent_framework import
import sys, os as _os
sys.path.insert(0, str(__import__('pathlib').Path(__file__).parent.parent))
from compat import apply_patches
apply_patches()

from agent_framework import (
    ChatAgent,
    ChatMessage,
    Executor,
    ExecutorFailedEvent,
    WorkflowBuilder,
    WorkflowContext,
    WorkflowFailedEvent,
    WorkflowOutputEvent,
    WorkflowRunState,
    WorkflowStatusEvent,
    handler,
)
# AzureAIClient requires a configured Foundry project — import conditionally
try:
    from agent_framework.azure import AzureAIClient as _AzureAIClient  # noqa: F401
except ImportError:
    _AzureAIClient = None  # type: ignore

from core.checkpoint_manager import CheckpointManager
from core.consensus_engine import ConsensusEngine
from core.log_manager import LogManager, LogLevel
from core.monitoring import RuntimeMonitor
from core.models import (
    AdminTodoItem,
    AgentDescriptor,
    AgentMessage,
    AgentRole,
    OrchestratorState,
    Task,
    TaskStatus,
    TrustLevel,
)
from core.multi_model_dispatcher import MultiModelDispatcher
from core.pki_manager import PKIManager
from core.task_manager import TaskManager
from core.viewpoint_init import ViewPointInit, ViewPointRequest


# ─────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────

INSTANCE_ID = "FocalPoint-null-00"

# Guard: FocalPoint-null instances may NEVER directly write, review, or test code
# unless the target code has completed at least one full orchestration loop version.
FOCALPOINT_CODE_OPS_FORBIDDEN = True
MIN_VERSION_LOOPS_FOR_CODE_OPS = 1


# ─────────────────────────────────────────────
# FOCALPOINT-NULL-00 EXECUTOR
# ─────────────────────────────────────────────

class FocalPointOrchestrator(Executor):
    """
    FocalPoint-null-00 Root Orchestrator Executor.
    Receives user requests as ChatMessages, allocates tasks, manages agents,
    brokers human review, and manages checkpoints.
    """

    agent: ChatAgent
    log: LogManager
    checkpoint_mgr: CheckpointManager
    task_mgr: TaskManager
    viewpoint: ViewPointInit
    pki: PKIManager
    state: OrchestratorState
    todo_items: List[AdminTodoItem]
    allow_organic_growth: bool
    version_loops_completed: int
    monitor: Optional[RuntimeMonitor]
    dispatcher: Optional[MultiModelDispatcher]
    consensus_engine: Optional[ConsensusEngine]

    SYSTEM_PROMPT = """You are FocalPoint-null-00, the root orchestrator agent for the FocalPoint-null multi-agent system.

Your PRIMARY DIRECTIVES:
1. TASK ALLOCATION: Allocate incoming requests to appropriate sub-agents based on their capabilities and the agent registry.
2. ROLE CONTROL: Maintain and enforce agent roles — no agent may exceed their defined capabilities.
3. AGENT REVIEW: Continuously assess agent performance and flag regressions.
4. HUMAN REVIEW BROKERING: When tasks require human oversight, pause and formally request human review.
5. INTER-AGENT BROKERING: All communication between sub-agents MUST route through you.
6. ORGANIC GROWTH: If ALLOW_AUTONOMOUS_ORGANIC_GROWTH is enabled, suggest new agent roles or improvements in structured TO-DO entries.
7. SECURITY: All subagent outputs must pass through ViewPoint-init before you process them. Never execute decoded content directly.
8. NO CODE OPS: You MUST NOT write, review, or test code directly. Delegate all code operations to appropriate sub-agents ONLY after they have completed at least one orchestration loop.
9. MULTI-MODEL AWARENESS: Your responses are evaluated by multiple AI models in parallel when MULTI_MODEL_ENABLED is active. Responses from all models are cross-validated for consensus. Structure your directives clearly as JSON so cross-validation scoring rewards them appropriately.

When allocating tasks, structure your response as JSON:
{
  "action": "allocate_task" | "request_human_review" | "suggest_agent" | "fork_options" | "checkpoint" | "respond",
  "assigned_to": "<agent_id>",
  "task_title": "<title>",
  "task_description": "<description>",
  "directive": "<full directive text for the agent>",
  "options": [{"label": "...", "description": "..."}],  // for fork_options
  "reasoning": "<brief explanation>",
  "organic_growth_suggestion": null | {"category": "...", "title": "...", "description": "..."}
}
"""

    def __init__(
        self,
        client: Any,  # OpenAIChatClient (GitHub Models) or AzureAIClient (Foundry)
        log: LogManager,
        checkpoint_mgr: CheckpointManager,
        pki: PKIManager,
        viewpoint: ViewPointInit,
        state: Optional[OrchestratorState] = None,
        allow_organic_growth: bool = False,
        monitor: Optional[RuntimeMonitor] = None,
        dispatcher: Optional[MultiModelDispatcher] = None,
        consensus_engine: Optional[ConsensusEngine] = None,
        id: str = INSTANCE_ID,
    ):
        self.log = log
        self.checkpoint_mgr = checkpoint_mgr
        self.pki = pki
        self.viewpoint = viewpoint
        self.allow_organic_growth = allow_organic_growth
        self.monitor = monitor
        self.dispatcher = dispatcher
        self.consensus_engine = consensus_engine
        self.todo_items: List[AdminTodoItem] = []

        # Resume from checkpoint or create fresh state
        if state is None:
            resumed = checkpoint_mgr.load_latest_checkpoint()
            if resumed:
                self.state = resumed
                log.log(LogLevel.INFO, INSTANCE_ID,
                        f"Resumed from checkpoint — {len(resumed.active_tasks)} active tasks, "
                        f"{resumed.version_loops_completed} version loops completed")
            else:
                self.state = OrchestratorState(instance_id=INSTANCE_ID)
                log.log(LogLevel.INFO, INSTANCE_ID, "FocalPoint-null-00 initialized — no prior checkpoint")
        else:
            self.state = state

        self.version_loops_completed = self.state.version_loops_completed

        self.task_mgr = TaskManager(
            state=self.state,
            log_manager=log,
            max_retries=int(os.getenv("TASK_MAX_RETRIES", "3")),
            max_fork_depth=int(os.getenv("MAX_FORK_DEPTH", "3")),
            max_fork_paths=int(os.getenv("MAX_FORK_PATHS", "10")),
        )

        # Create orchestrator's chat agent
        self.agent = client.create_agent(
            name=INSTANCE_ID,
            instructions=self.SYSTEM_PROMPT,
        )

        super().__init__(id=id)

    # ─────────────────────────────────────────────
    # MAIN HANDLER
    # ─────────────────────────────────────────────

    @handler
    async def orchestrate(
        self,
        messages: list[ChatMessage],
        ctx: WorkflowContext[ChatMessage],
    ) -> None:
        """
        Main orchestration loop handler.
        Receives messages, runs the orchestrator LLM, interprets directives,
        dispatches tasks, manages forks, checkpoints and growth suggestions.
        """
        if self.monitor:
            self.monitor.mark_received(INSTANCE_ID)
            self.monitor.start_processing(INSTANCE_ID)

        try:
            self.log.log_prompt(
                INSTANCE_ID,
                prompt_input="\n".join(m.text or "" for m in messages),
                prompt_output="<pending>",
                is_focalpoint=True,
            )

            # Run orchestrator — uses multi-model consensus when dispatcher is active
            response = await self._run_with_consensus(messages)

            # Log prompt output
            self.log.log_prompt(
                INSTANCE_ID,
                prompt_input="",
                prompt_output=response.text or "",
                is_focalpoint=True,
            )

            # Parse orchestrator decision
            decision = self._parse_decision(response.text or "")

            # Increment version loop counter
            self.version_loops_completed += 1
            self.state.version_loops_completed = self.version_loops_completed
            self.state.last_active_at = datetime.now(timezone.utc)

            # Execute decision
            result = await self._execute_decision(decision, messages)

            # Auto-checkpoint every loop
            checkpoint = self.checkpoint_mgr.save_checkpoint(self.state)
            self.log.log_checkpoint(checkpoint.checkpoint_id, INSTANCE_ID)

            # Handle admin TO-DO suggestions from organic growth
            if self.allow_organic_growth and decision.get("organic_growth_suggestion"):
                self._record_todo(decision["organic_growth_suggestion"], "organic_growth")

            # Forward result to next executor (WorkflowContext[T] requires single T, not list)
            reply_msg = ChatMessage(role="assistant", text=result)
            await ctx.send_message(reply_msg)
            if self.monitor:
                self.monitor.mark_sent(INSTANCE_ID)
        except Exception as ex:
            if self.monitor:
                self.monitor.mark_error(INSTANCE_ID, str(ex))
            raise
        finally:
            if self.monitor:
                self.monitor.stop_processing(INSTANCE_ID)

    # ─────────────────────────────────────────────
    # MULTI-MODEL CONSENSUS DISPATCH
    # ─────────────────────────────────────────────

    async def _run_with_consensus(self, messages: list) -> Any:
        """
        Run the orchestrator prompt through multi-model parallel dispatch + consensus
        when a MultiModelDispatcher is configured. Falls back to single-model
        self.agent.run() transparently when no dispatcher is present.

        Returns an object with a .text attribute (same interface as agent.run()).
        """
        if self.dispatcher is None or self.consensus_engine is None:
            return await self.agent.run(messages)

        # Convert agent ChatMessage objects to plain dicts for HTTP dispatch
        msg_dicts = []
        for m in messages:
            role = getattr(m, "role", "user") or "user"
            text = getattr(m, "text", "") or ""
            msg_dicts.append({"role": role, "content": text})

        # Parallel dispatch to all configured endpoints
        transaction = await self.dispatcher.dispatch(
            messages=msg_dicts,
            task_id=None,    # Orchestrator-level call — not tied to a specific sub-task
        )

        # Cross-validate and select highest-confidence winner
        consensus = self.consensus_engine.evaluate(transaction)

        if consensus.all_failed:
            self.log.log(
                LogLevel.WARNING,
                INSTANCE_ID,
                "Multi-model: all endpoints failed — falling back to primary single-model agent",
            )
            return await self.agent.run(messages)

        self.log.log(
            LogLevel.AUDIT,
            INSTANCE_ID,
            f"Multi-model consensus: winner={consensus.winner_endpoint_id} "
            f"confidence={consensus.confidence:.3f} "
            f"failover={consensus.failover_applied} "
            f"fusion={consensus.fusion_applied} "
            f"txn={consensus.transaction_id}",
        )

        # Wrap in a simple object matching the agent.run() response interface
        class _ConsensusResponse:
            def __init__(self, text: str) -> None:
                self.text = text

        return _ConsensusResponse(consensus.winner_text)

    # ─────────────────────────────────────────────
    # DECISION EXECUTION
    # ─────────────────────────────────────────────

    async def _execute_decision(self, decision: Dict[str, Any], messages: list[ChatMessage]) -> str:
        action = decision.get("action", "respond")

        if action == "allocate_task":
            return await self._handle_task_allocation(decision)

        elif action == "request_human_review":
            return self._handle_human_review_request(decision)

        elif action == "fork_options":
            return self._handle_fork_creation(decision)

        elif action == "suggest_agent":
            return self._handle_agent_suggestion(decision)

        elif action == "checkpoint":
            checkpoint = self.checkpoint_mgr.save_checkpoint(self.state)
            return f"[FocalPoint-null-00] Checkpoint saved: {checkpoint.checkpoint_id}"

        else:
            return decision.get("reasoning", "Acknowledged.")

    async def _handle_task_allocation(self, decision: Dict[str, Any]) -> str:
        assigned_to = decision.get("assigned_to", "")
        if not assigned_to:
            return "[FocalPoint-null-00] Cannot allocate task — no target agent specified."

        # Validate agent exists and PKI cert is valid
        if not self.pki.is_cert_valid(assigned_to):
            self.log.log(LogLevel.WARNING, INSTANCE_ID,
                         f"PKI warning: agent {assigned_to} certificate not valid or missing")

        task = self.task_mgr.create_task(
            title=decision.get("task_title", "Untitled Task"),
            description=decision.get("task_description", ""),
            assigned_to=assigned_to,
            dispatched_by=INSTANCE_ID,
            directive_text=decision.get("directive", ""),
        )
        self.task_mgr.mark_dispatched(task.task_id)

        self.log.log(LogLevel.INFO, INSTANCE_ID,
                     f"Task allocated to {assigned_to}: {task.task_id}")

        return (
            f"[FocalPoint-null-00] Task '{task.title}' allocated to {assigned_to}. "
            f"Task ID: {task.task_id}. "
            f"Reasoning: {decision.get('reasoning', '')}"
        )

    def _handle_human_review_request(self, decision: Dict[str, Any]) -> str:
        notes = decision.get("reasoning", "Human review requested.")
        # Find the most recent active task related to this request
        recent_task = next(
            (t for t in reversed(list(self.state.active_tasks.values()))
             if t.status not in [TaskStatus.COMPLETED, TaskStatus.FAILED]),
            None,
        )
        if recent_task:
            self.task_mgr.request_human_review(recent_task.task_id, notes, INSTANCE_ID)

        self._record_todo(
            {
                "category": "human_oversight_required",
                "title": f"Human review needed: {decision.get('task_title', 'Task')}",
                "description": notes,
            },
            "human_review",
        )

        return f"[FocalPoint-null-00] HUMAN REVIEW REQUESTED. {notes}"

    def _handle_fork_creation(self, decision: Dict[str, Any]) -> str:
        options = decision.get("options", [])
        if not options:
            return "[FocalPoint-null-00] Fork creation skipped — no options provided."

        # Find parent task
        recent_task = next(
            (t for t in reversed(list(self.state.active_tasks.values()))
             if t.status in [TaskStatus.PENDING, TaskStatus.DISPATCHED, TaskStatus.IN_PROGRESS]),
            None,
        )
        parent_id = recent_task.task_id if recent_task else str(uuid4())

        forkset = self.task_mgr.create_fork_set(
            parent_task_id=parent_id,
            options=options,
        )
        if not forkset:
            return "[FocalPoint-null-00] Fork creation blocked by depth/growth limits."

        return (
            f"[FocalPoint-null-00] ForkSet created: {forkset.forkset_id} "
            f"with {len(forkset.forks)} paths. Each option will be pursued independently."
        )

    def _handle_agent_suggestion(self, decision: Dict[str, Any]) -> str:
        if not self.allow_organic_growth:
            self._record_todo(
                {
                    "category": "new_agents",
                    "title": decision.get("task_title", "New Agent Suggestion"),
                    "description": decision.get("reasoning", ""),
                    "priority": "MEDIUM",
                },
                "suggestion",
            )
            return (
                "[FocalPoint-null-00] New agent suggestion recorded to Admin TO-DO. "
                "Autonomous organic growth is DISABLED — awaiting admin approval."
            )
        return f"[FocalPoint-null-00] Agent suggestion noted: {decision.get('reasoning', '')}"

    # ─────────────────────────────────────────────
    # SUB-AGENT RESULT INGESTION (via ViewPoint)
    # ─────────────────────────────────────────────

    def receive_subagent_result(
        self,
        source_agent_id: str,
        raw_result: Any,
        task_id: str,
        permitted_additional: Optional[List[str]] = None,
    ) -> Dict[str, Any]:
        """
        Receive a sub-agent result through ViewPoint-init encoding.
        FocalPoint NEVER sees the raw result directly.
        Returns the safe, encoded response dict for the orchestrator to record.
        """
        request = ViewPointRequest(
            request_id=str(uuid4()),
            invoking_focalpoint_id=INSTANCE_ID,
            source_agent_id=source_agent_id,
            raw_output=raw_result,
            permitted_recipients=permitted_additional,
        )

        encoded_response = self.viewpoint.encode_subagent_output(request)

        if not self.viewpoint.verify_response_integrity(encoded_response):
            self.log.log(LogLevel.SECURITY, INSTANCE_ID,
                         f"ViewPoint integrity check FAILED for {source_agent_id} — result discarded",
                         task_id=task_id)
            return {"error": "ViewPoint integrity verification failed", "task_id": task_id}

        # Mark task completed with encoded result
        if task_id in self.state.active_tasks:
            self.task_mgr.mark_completed(
                task_id,
                result=encoded_response.to_safe_dict(),
                agent_id=source_agent_id,
                result_viewpoint_encoded=True,
            )

        return encoded_response.to_safe_dict()

    # ─────────────────────────────────────────────
    # ADMIN TO-DO
    # ─────────────────────────────────────────────

    def _record_todo(self, suggestion: Dict[str, Any], source: str) -> AdminTodoItem:
        item = AdminTodoItem(
            category=suggestion.get("category", "general"),
            title=suggestion.get("title", "Untitled recommendation"),
            description=suggestion.get("description", ""),
            suggested_by=INSTANCE_ID,
            priority=suggestion.get("priority", "MEDIUM"),
        )
        self.todo_items.append(item)

        # Persist to todo directory
        todo_dir = os.getenv("TODO_DIR", "todo")
        import pathlib
        pathlib.Path(todo_dir).mkdir(parents=True, exist_ok=True)
        todo_path = pathlib.Path(todo_dir) / f"todo-{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S')}-{item.todo_id[:8]}.json"
        todo_path.write_text(item.model_dump_json(indent=2), encoding="utf-8")

        self.log.log(LogLevel.INFO, INSTANCE_ID,
                     f"Admin TO-DO recorded [{item.category}]: {item.title}")
        return item

    # ─────────────────────────────────────────────
    # INTER-AGENT BROKERING
    # ─────────────────────────────────────────────

    def broker_message(
        self,
        from_agent: str,
        to_agent: str,
        payload: Any,
        sign_as: str = INSTANCE_ID,
    ) -> AgentMessage:
        """
        Broker a message between two agents.
        FocalPoint-null-00 signs the brokered message with its PKI key.
        """
        payload_json = json.dumps(payload, default=str)
        try:
            sha256, signature = self.pki.sign_payload(sign_as, payload_json)
        except Exception:
            sha256 = hashlib.sha256(payload_json.encode()).hexdigest()
            signature = None

        msg = AgentMessage(
            from_agent=from_agent,
            to_agent=to_agent,
            brokered_by=INSTANCE_ID,
            payload=payload,
            payload_sha256=sha256,
            sender_signature=signature,
        )
        self.log.log(LogLevel.AUDIT, INSTANCE_ID,
                     f"Brokered message: {from_agent} -> {to_agent} (sha256={sha256[:12]}...)")
        return msg

    # ─────────────────────────────────────────────
    # INTERNAL HELPERS
    # ─────────────────────────────────────────────

    def _parse_decision(self, response_text: str) -> Dict[str, Any]:
        """Parse LLM response as JSON decision. Falls back to plain respond."""
        # Try to extract JSON block
        text = response_text.strip()
        start = text.find("{")
        end = text.rfind("}") + 1
        if start >= 0 and end > start:
            try:
                return json.loads(text[start:end])
            except json.JSONDecodeError:
                pass
        return {"action": "respond", "reasoning": response_text}

    def get_status_report(self) -> Dict[str, Any]:
        """Return a comprehensive orchestrator status report."""
        multi_model_info: Dict[str, Any] = {"enabled": False}
        if self.dispatcher is not None:
            multi_model_info = {
                "enabled": True,
                "endpoint_count": len(self.dispatcher.endpoints),
                "endpoints": [
                    {
                        "id": ep.endpoint_id,
                        "model": ep.model_name,
                        "weight": ep.weight,
                        "is_primary": ep.is_primary,
                    }
                    for ep in self.dispatcher.endpoints
                ],
                "failover_threshold": (
                    self.consensus_engine.failover_threshold
                    if self.consensus_engine is not None
                    else None
                ),
            }
        return {
            "instance_id": INSTANCE_ID,
            "version_loops_completed": self.version_loops_completed,
            "allow_organic_growth": self.allow_organic_growth,
            "task_summary": self.task_mgr.get_summary(),
            "access_summary": self.log.get_access_summary(),
            "pending_todo_count": len([t for t in self.todo_items if t.status == "OPEN"]),
            "last_active": self.state.last_active_at.isoformat(),
            "multi_model": multi_model_info,
        }







