# VersionTag: 2605.B5.V46.0
# VersionTag: 2605.B5.V46.0
# VersionTag: 2605.B5.V46.0
# VersionTag: 2605.B5.V46.0
"""
FocalPoint-null Core Data Models
Pydantic models for all system entities: agents, tasks, forks, checkpoints, log entries.
"""
from __future__ import annotations

import uuid
from datetime import datetime, timezone
from enum import Enum
from typing import Any, Dict, List, Optional

from pydantic import BaseModel, Field


# ─────────────────────────────────────────────
# ENUMERATIONS
# ─────────────────────────────────────────────

class TrustLevel(str, Enum):
    ROOT = "ROOT"
    SANDBOX = "SANDBOX"
    SANDBOXED_SECURITY = "SANDBOXED_SECURITY"
    REVIEW = "REVIEW"
    QUALITY = "QUALITY"
    STANDARDS = "STANDARDS"
    COMPILER = "COMPILER"
    TESTER = "TESTER"
    SUBAGENT = "SUBAGENT"


class AgentRole(str, Enum):
    ORCHESTRATOR = "ORCHESTRATOR"
    SECURITY_PROXY = "SECURITY_PROXY"
    SECURITY = "SECURITY"
    REVIEW = "REVIEW"
    QUALITY = "QUALITY"
    STANDARDS = "STANDARDS"
    COMPILER = "COMPILER"
    TESTER = "TESTER"
    SUBAGENT = "SUBAGENT"


class TaskStatus(str, Enum):
    PENDING = "PENDING"
    DISPATCHED = "DISPATCHED"
    IN_PROGRESS = "IN_PROGRESS"
    AWAITING_HUMAN = "AWAITING_HUMAN"
    COMPLETED = "COMPLETED"
    FAILED = "FAILED"
    RETRYING = "RETRYING"
    CANCELLED = "CANCELLED"
    FORKED = "FORKED"


class CertStatus(str, Enum):
    PENDING_GENERATION = "PENDING_GENERATION"
    ACTIVE = "ACTIVE"
    REVOKED = "REVOKED"
    EXPIRED = "EXPIRED"


class ForkStatus(str, Enum):
    ACTIVE = "ACTIVE"
    TESTING = "TESTING"
    COMPLETED = "COMPLETED"
    LOCKED = "LOCKED"    # Post-test: no further autonomous forking allowed
    FAILED = "FAILED"


class ResourceType(str, Enum):
    FILE = "file_access"
    WEBSITE = "website_request"
    MEMORY = "memory_request"
    CHECKPOINT = "checkpoint_event"
    ACTION = "action"
    PROMPT_INPUT = "prompt_input"
    PROMPT_OUTPUT = "prompt_output"


class LogLevel(str, Enum):
    DEBUG = "DEBUG"
    INFO = "INFO"
    WARNING = "WARNING"
    ERROR = "ERROR"
    CRITICAL = "CRITICAL"
    SECURITY = "SECURITY"
    AUDIT = "AUDIT"


# ─────────────────────────────────────────────
# PKI / AGENT IDENTITY
# ─────────────────────────────────────────────

class AgentPKIConfig(BaseModel):
    cert_file: Optional[str] = None
    public_key_file: Optional[str] = None
    cert_status: CertStatus = CertStatus.PENDING_GENERATION
    cert_fingerprint_sha256: Optional[str] = None
    issued_at: Optional[datetime] = None
    expires_at: Optional[datetime] = None


class AgentCertificate(BaseModel):
    agent_id: str
    public_key_pem: str
    cert_pem: str
    fingerprint_sha256: str
    issued_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))
    expires_at: datetime
    is_revoked: bool = False


# ─────────────────────────────────────────────
# AGENT DESCRIPTOR
# ─────────────────────────────────────────────

class AgentDescriptor(BaseModel):
    agent_id: str
    display_name: Optional[str] = None
    role: AgentRole
    description: str
    trust_level: TrustLevel
    sequence: int = 0
    allows_code_ops: bool = False
    min_version_loops: int = 0
    capabilities: List[str] = Field(default_factory=list)
    pki: AgentPKIConfig = Field(default_factory=AgentPKIConfig)
    is_active: bool = True
    created_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))
    version_loops_completed: int = 0


# ─────────────────────────────────────────────
# INTER-AGENT MESSAGE
# ─────────────────────────────────────────────

class AgentMessage(BaseModel):
    message_id: str = Field(default_factory=lambda: str(uuid.uuid4()))
    from_agent: str
    to_agent: str
    brokered_by: Optional[str] = None       # FocalPoint instance that brokered this
    payload: Any
    # ViewPoint-init encodes subagent output as base64 transform
    is_viewpoint_encoded: bool = False
    viewpoint_encoding: Optional[str] = None   # e.g., "base64"
    viewpoint_agent_id: Optional[str] = None
    # PKI signature of payload SHA256
    payload_sha256: Optional[str] = None
    sender_signature: Optional[str] = None     # Base64 RSA signature
    timestamp: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))
    # Access restriction for ViewPoint messages
    permitted_recipients: List[str] = Field(default_factory=list)


# ─────────────────────────────────────────────
# TASK
# ─────────────────────────────────────────────

class TaskDirective(BaseModel):
    """Snapshot of agent directive at time of task receipt — immutable after creation."""
    directive_id: str = Field(default_factory=lambda: str(uuid.uuid4()))
    agent_id: str
    directive_text: str
    directive_sha256: str                      # SHA256 hash of directive text at receipt
    received_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))
    signed_by: Optional[str] = None            # FocalPoint that sent directive


class Task(BaseModel):
    task_id: str = Field(default_factory=lambda: str(uuid.uuid4()))
    title: str
    description: str
    assigned_to: str                           # Agent ID
    dispatched_by: str                         # FocalPoint instance ID
    status: TaskStatus = TaskStatus.PENDING
    directive_snapshot: Optional[TaskDirective] = None
    fork_id: Optional[str] = None             # If this task belongs to a fork path
    fork_option_label: Optional[str] = None
    parent_task_id: Optional[str] = None
    child_task_ids: List[str] = Field(default_factory=list)
    # Retry management
    retry_count: int = 0
    max_retries: int = 3
    last_error: Optional[str] = None
    # Progress tracking
    progress_pct: float = 0.0
    progress_notes: List[str] = Field(default_factory=list)
    # Timestamps
    created_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))
    dispatched_at: Optional[datetime] = None
    started_at: Optional[datetime] = None
    completed_at: Optional[datetime] = None
    # Result
    result: Optional[Any] = None
    result_sha256: Optional[str] = None
    # Viewpoint encoding applied to result?
    result_viewpoint_encoded: bool = False
    # Human review
    human_review_requested: bool = False
    human_review_notes: Optional[str] = None


# ─────────────────────────────────────────────
# FORK PATH
# ─────────────────────────────────────────────

class ForkPath(BaseModel):
    fork_id: str = Field(default_factory=lambda: str(uuid.uuid4()))
    parent_task_id: str
    option_label: str
    option_description: str
    status: ForkStatus = ForkStatus.ACTIVE
    depth: int = 0
    # Assigned task IDs in this fork
    task_ids: List[str] = Field(default_factory=list)
    # After testing completes, lock against further growth
    test_completed: bool = False
    autonomy_locked: bool = False
    created_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))
    completed_at: Optional[datetime] = None
    created_by: str = "FocalPoint-null-00"


class ForkSet(BaseModel):
    """Group of fork paths created for a multi-option agent response."""
    forkset_id: str = Field(default_factory=lambda: str(uuid.uuid4()))
    parent_task_id: str
    origin_option_count: int
    forks: List[ForkPath] = Field(default_factory=list)
    created_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))
    # True once ALL forks in this set have been tested
    all_tested: bool = False


# ─────────────────────────────────────────────
# CHECKPOINT
# ─────────────────────────────────────────────

class CheckpointMetadata(BaseModel):
    """Metadata tag attached to checkpoint archives for agent re-access control."""
    allow_agent_archival_access: bool = False
    permitted_agent_ids: List[str] = Field(default_factory=list)
    permitted_agent_public_keys: Dict[str, str] = Field(default_factory=dict)  # agent_id -> pem
    archive_sha256: str
    created_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))
    archived_at: Optional[datetime] = None


class Checkpoint(BaseModel):
    checkpoint_id: str = Field(default_factory=lambda: str(uuid.uuid4()))
    focalpoint_instance: str                   # e.g., "FocalPoint-null-00"
    state_type: str                            # e.g., "orchestrator_state", "task_state"
    state_data: Dict[str, Any]
    active_task_ids: List[str] = Field(default_factory=list)
    active_fork_ids: List[str] = Field(default_factory=list)
    created_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))
    # SHA256 of state_data JSON for validation
    state_sha256: str
    # Signed by FocalPoint PKI key
    signature: Optional[str] = None
    metadata: CheckpointMetadata = Field(default_factory=CheckpointMetadata)


# ─────────────────────────────────────────────
# ACCESS LOG ENTRY
# ─────────────────────────────────────────────

class AccessLogEntry(BaseModel):
    entry_id: str = Field(default_factory=lambda: str(uuid.uuid4()))
    agent_id: str
    is_focalpoint: bool = False
    resource_type: ResourceType
    resource_ref: str                          # File path, URL, memory key, etc.
    is_secured: bool = True                    # Was this call made over secured channel?
    call_method: Optional[str] = None         # e.g., "PKI_SIGNED", "PLAIN_HTTP", "LOCAL_FILE"
    process_id: Optional[int] = None
    thread_id: Optional[str] = None
    task_id: Optional[str] = None
    timestamp: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))
    result_status: str = "OK"                  # e.g., "OK", "DENIED", "ERROR"
    notes: Optional[str] = None


# ─────────────────────────────────────────────
# AGENT REVIEW REPORT
# ─────────────────────────────────────────────

class AgentReviewReport(BaseModel):
    report_id: str = Field(default_factory=lambda: str(uuid.uuid4()))
    reviewed_by: str = "AgentReview-00"
    review_subject_agent: str
    task_id: Optional[str] = None
    performance_score: Optional[float] = None  # 0.0 - 1.0
    issues_found: List[str] = Field(default_factory=list)
    regressions_detected: List[str] = Field(default_factory=list)
    improvement_suggestions: List[str] = Field(default_factory=list)
    new_role_suggestions: List[str] = Field(default_factory=list)
    interop_notes: List[str] = Field(default_factory=list)
    created_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))


# ─────────────────────────────────────────────
# ADMIN TO-DO
# ─────────────────────────────────────────────

class AdminTodoItem(BaseModel):
    todo_id: str = Field(default_factory=lambda: str(uuid.uuid4()))
    category: str                              # new_agents, agent_changes, human_oversight_required, etc.
    title: str
    description: str
    suggested_by: str                          # Agent ID that generated this
    priority: str = "MEDIUM"                   # LOW, MEDIUM, HIGH, CRITICAL
    status: str = "OPEN"                       # OPEN, ACKNOWLEDGED, IN_PROGRESS, DONE, REJECTED
    created_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))
    acknowledged_at: Optional[datetime] = None
    notes: Optional[str] = None


# ─────────────────────────────────────────────
# ORCHESTRATOR STATE (for checkpoint)
# ─────────────────────────────────────────────

class OrchestratorState(BaseModel):
    instance_id: str
    active_tasks: Dict[str, Task] = Field(default_factory=dict)
    active_forks: Dict[str, ForkSet] = Field(default_factory=dict)
    completed_task_count: int = 0
    failed_task_count: int = 0
    version_loops_completed: int = 0
    agent_registry_snapshot: List[AgentDescriptor] = Field(default_factory=list)
    last_checkpoint_id: Optional[str] = None
    started_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))
    last_active_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))


# ─────────────────────────────────────────────
# CODE SIN REGISTRY — Code-B-iSmuth / Code-B-Tsted
# ─────────────────────────────────────────────

class SinSeverity(str, Enum):
    CRITICAL = "CRITICAL"
    HIGH = "HIGH"
    MEDIUM = "MEDIUM"
    LOW = "LOW"
    INFO = "INFO"


class SinCategory(str, Enum):
    SECURITY = "SECURITY"
    VERSION = "VERSION"
    ACCESS_VIOLATION = "ACCESS_VIOLATION"
    UNTRAPPED_ERROR = "UNTRAPPED_ERROR"
    LOGIC = "LOGIC"
    STANDARDS = "STANDARDS"
    REGRESSION = "REGRESSION"
    SYNTAX = "SYNTAX"
    EXIT_LOGIC = "EXIT_LOGIC"
    DEPENDENCY = "DEPENDENCY"
    OTHER = "OTHER"


class FixStatus(str, Enum):
    PENDING = "PENDING"               # No fix found yet — review in progress
    INVESTIGATING = "INVESTIGATING"   # Root cause analysis underway
    PILOT = "PILOT"                   # Fix piloted — not yet verified across 4 uses
    TRUSTED = "TRUSTED"               # Fix applied successfully in >= 4 cases
    REVOKED = "REVOKED"               # Fix was itself a problem — revoked


class CodeFix(BaseModel):
    """A verified fix for a known code sin. Becomes TRUSTED after 4 successful applications."""
    fix_id: str = Field(default_factory=lambda: str(uuid.uuid4()))
    sin_id: str                                   # References CodeSin.sin_id
    description: str                              # Plain description of the fix
    fix_diff_summary: str                         # Summary of changes applied
    fix_status: FixStatus = FixStatus.PILOT
    applied_count: int = 0                        # Times this fix was applied
    trusted_threshold: int = 4                    # Applications needed for TRUSTED status
    known_introduced_failures: List[str] = Field(default_factory=list)  # Side-effect failures
    additional_failures_count: int = 0            # Count of failures this fix may introduce
    created_by: str                               # Agent that created the fix
    created_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))
    trusted_at: Optional[datetime] = None         # When promoted to TRUSTED
    detection_hash: Optional[str] = None          # SHA256 detection pattern hash
    pilot_milestone_at: Optional[datetime] = None
    trusted_milestone_at: Optional[datetime] = None
    applied_cases: List[str] = Field(default_factory=list)  # Task IDs where applied


class CodeSin(BaseModel):
    """
    A code problem / defect / failure event.
    Remembers how, why, where, when and how many times an issue occurred.
    Maps to known trusted fixes over time. Generates detection hashes for rapid redetection.
    """
    sin_id: str = Field(default_factory=lambda: str(uuid.uuid4()))
    title: str
    description: str
    severity: SinSeverity = SinSeverity.MEDIUM
    category: SinCategory = SinCategory.OTHER
    # Where it was found
    file_path: Optional[str] = None
    line_number: Optional[int] = None
    function_name: Optional[str] = None
    agent_id: str                             # Agent code that contained the sin
    reported_by: str                          # Agent that detected it
    # How it was found
    detection_method: str = ""               # Test run, static analysis, review, runtime trace
    detection_hash: Optional[str] = None     # SHA256 of (title + category + file_path) for rapid redetection
    # Why it happened
    root_cause: Optional[str] = None
    root_cause_analysis: Optional[str] = None
    # Version / security / access flags
    is_security_related: bool = False
    is_version_related: bool = False
    is_access_violation: bool = False
    is_untrapped_error: bool = False
    # Recurrence tracking
    occurrence_count: int = 1
    first_seen_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))
    last_seen_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))
    location_history: List[str] = Field(default_factory=list)  # file_path history across occurrences
    task_ids: List[str] = Field(default_factory=list)           # Task IDs where seen
    # Fix linkage
    fix_id: Optional[str] = None             # Current best fix (references CodeFix.fix_id)
    fix_status: FixStatus = FixStatus.PENDING
    regression_count: int = 0                # Times this sin caused a detectable regression
    # Status
    is_resolved: bool = False
    resolved_at: Optional[datetime] = None
    reviewed_by_agents: List[str] = Field(default_factory=list)


class CodeSinReport(BaseModel):
    """Output report produced by Code-B-Tsted after a test run."""
    report_id: str = Field(default_factory=lambda: str(uuid.uuid4()))
    produced_by: str = "Code-B-Tsted-00"
    task_id: Optional[str] = None
    target_agent: str                         # Which agent's code was tested
    test_type: str                            # "syntax", "security", "standards", "exit_logic", "full"
    sins_detected: List[str] = Field(default_factory=list)   # sin_ids
    new_sins_count: int = 0
    known_sins_recurred: int = 0
    trusted_fixes_applied: int = 0
    pilot_fixes_applied: int = 0
    regressions_detected: int = 0
    test_passed: bool = False
    test_summary: str = ""
    trace_log: List[str] = Field(default_factory=list)
    recommendations: List[str] = Field(default_factory=list)
    created_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))


class CompilerOutput(BaseModel):
    """Structured output from Code-B-iSmuth after a code generation or compilation task."""
    output_id: str = Field(default_factory=lambda: str(uuid.uuid4()))
    produced_by: str = "Code-B-iSmuth-00"
    task_id: Optional[str] = None
    file_path: str
    language: str
    code_summary: str                         # Plain summary of what was generated/compiled
    referenced_modules: List[str] = Field(default_factory=list)  # Existing modules reused
    governance_feedback_applied: List[str] = Field(default_factory=list)  # Advice from each agent
    known_sins_avoided: List[str] = Field(default_factory=list)            # sin_ids actively avoided
    trusted_fixes_honoured: List[str] = Field(default_factory=list)        # fix_ids respected
    ready_for_handover: bool = False           # True = handed to Code-B-Tsted
    handover_checklist: Dict[str, bool] = Field(default_factory=dict)  # security, syntax, standards, exit_logic, error_trapping
    created_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))


# ─────────────────────────────────────────────
# MULTI-MODEL PARALLEL DISPATCH — MultiModelProxy-00
# VersionTag: 2605.B5.V46.0
# ─────────────────────────────────────────────

class ModelEndpointConfig(BaseModel):
    """Configuration for a single AI model endpoint in multi-model dispatch."""
    endpoint_id: str
    base_url: str
    api_key: str               # NEVER hardcoded — loaded from env var at runtime (P001)
    model_name: str
    weight: float = 1.0        # Trust weight for consensus scoring (0.0–1.0)
    timeout_seconds: float = 30.0
    temperature: float = 0.7
    max_tokens: Optional[int] = None
    is_primary: bool = False
    is_enabled: bool = True


class ModelResponse(BaseModel):
    """A single model's raw response from one endpoint in a dispatch transaction."""
    response_id: str = Field(default_factory=lambda: str(uuid.uuid4()))
    endpoint_id: str
    transaction_id: str
    model_name: str
    text: str = ""
    latency_ms: int = 0
    error: Optional[str] = None        # Non-None means this endpoint failed
    weight: float = 1.0
    prompt_tokens: Optional[int] = None
    completion_tokens: Optional[int] = None
    received_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))


class WitnessEntry(BaseModel):
    """
    Cryptographic audit record for a single model response.
    Provides trust, transaction and witnessing for inter-model result streams.
    SHA256 of the full response payload JSON ensures tamper-evidence.
    """
    witness_id: str = Field(default_factory=lambda: str(uuid.uuid4()))
    transaction_id: str
    endpoint_id: str
    model_name: str
    response_sha256: str           # SHA256 of full serialised response payload
    response_length: int = 0
    has_error: bool = False
    latency_ms: int = 0
    weight: float = 1.0
    witnessed_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))


class ScoredResponse(BaseModel):
    """A model response annotated with quality scores computed by ConsensusEngine."""
    endpoint_id: str
    text: str
    length_score: float = 0.0      # 0.0–1.0 penalising empty/tiny or excessively long
    structure_score: float = 0.0   # 0.0–1.0 rewarding valid JSON structure
    agreement_score: float = 0.0   # 0.0–1.0 Jaccard similarity agreement with peer responses
    weight: float = 1.0            # Configured endpoint trust weight
    final_score: float = 0.0       # Weighted composite
    confidence: float = 0.0        # sqrt(final_score) for smoother curve
    latency_ms: int = 0


class DispatchTransaction(BaseModel):
    """Full audit record of one parallel multi-model dispatch operation."""
    transaction_id: str = Field(default_factory=lambda: str(uuid.uuid4()))
    task_id: Optional[str] = None
    messages_sha256: str           # SHA256 of the dispatched messages for tamper detection
    responses: List[ModelResponse] = Field(default_factory=list)
    witness_entries: List[WitnessEntry] = Field(default_factory=list)
    started_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))
    completed_at: Optional[datetime] = None
    endpoint_count: int = 0
    success_count: int = 0
    failure_count: int = 0


class ConsensusResult(BaseModel):
    """Output of the ConsensusEngine evaluation — the selected winner and scoring metadata."""
    consensus_id: str = Field(default_factory=lambda: str(uuid.uuid4()))
    transaction_id: str
    task_id: Optional[str] = None
    winner_endpoint_id: str
    winner_text: str
    confidence: float = 0.0        # 0.0–1.0
    all_failed: bool = False
    scored_responses: List[ScoredResponse] = Field(default_factory=list)
    failover_applied: bool = False
    fusion_applied: bool = False
    fusion_notes: List[str] = Field(default_factory=list)
    evaluated_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))








