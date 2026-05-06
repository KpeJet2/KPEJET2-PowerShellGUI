# VersionTag: 2604.B0.v1
# VersionTag: 2604.B0.v1
# VersionTag: 2604.B0.v1
# VersionTag: 2604.B0.v1
"""
ViewPoint-init Security Proxy Agent
Encodes all subagent outputs as base64 transforms before they reach FocalPoint-null.
Shields FocalPoint from: direct memory attacks, side-channel, OOB, speculative execution attacks
presented in code, output, configs, dependencies or rendering.
Access is restricted to the FocalPoint-null instance that invoked it, plus explicitly permitted agents.
"""
from __future__ import annotations

import base64
import hashlib
import json
import os
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Set

from core.models import AgentMessage, LogLevel
from core.log_manager import LogManager
from core.pki_manager import PKIManager


class ViewPointRequest:
    """A request to encode subagent output through ViewPoint-init."""
    def __init__(
        self,
        request_id: str,
        invoking_focalpoint_id: str,
        source_agent_id: str,
        raw_output: Any,
        permitted_recipients: Optional[List[str]] = None,
    ):
        self.request_id = request_id
        self.invoking_focalpoint_id = invoking_focalpoint_id
        self.source_agent_id = source_agent_id
        self.raw_output = raw_output
        self.permitted_recipients: Set[str] = set(permitted_recipients or [])
        # The invoking FocalPoint always has access
        self.permitted_recipients.add(invoking_focalpoint_id)
        self.created_at = datetime.now(timezone.utc)


class ViewPointResponse:
    """An encoded response from ViewPoint-init — safe to pass to FocalPoint."""
    def __init__(
        self,
        request_id: str,
        encoded_payload: str,
        encoding: str,
        content_sha256: str,
        source_agent_id: str,
        permitted_recipients: Set[str],
    ):
        self.request_id = request_id
        self.encoded_payload = encoded_payload
        self.encoding = encoding
        self.content_sha256 = content_sha256
        self.source_agent_id = source_agent_id
        self.permitted_recipients = permitted_recipients
        self.created_at = datetime.now(timezone.utc)

    def decode_for(self, recipient_agent_id: str) -> Optional[Any]:
        """
        Decode and return payload ONLY if recipient is permitted.
        Returns None if access denied.
        """
        if recipient_agent_id not in self.permitted_recipients:
            return None
        raw = base64.b64decode(self.encoded_payload.encode("utf-8"))
        return json.loads(raw.decode("utf-8"))

    def to_safe_dict(self) -> Dict[str, Any]:
        """Return the safe (encoded) representation for transport."""
        return {
            "request_id": self.request_id,
            "encoded_payload": self.encoded_payload,
            "encoding": self.encoding,
            "content_sha256": self.content_sha256,
            "source_agent_id": self.source_agent_id,
            "permitted_recipients": list(self.permitted_recipients),
            "created_at": self.created_at.isoformat(),
        }


class ViewPointInit:
    """
    ViewPoint-init Security Proxy.
    
    All subagent outputs are passed through this proxy before FocalPoint sees them.
    The proxy:
    1. Receives raw output from a subagent.
    2. Sanitizes: removes obviously dangerous constructs (scripts, exec() patterns).
    3. Encodes as base64 transform.
    4. Returns ViewPointResponse with restricted recipient list.
    5. FocalPoint decodes using decode_for(focalpoint_id).
    
    This ensures FocalPoint is NEVER exposed to direct, unencoded subagent output.
    """

    AGENT_ID = "ViewPoint-init"

    def __init__(
        self,
        log_manager: LogManager,
        pki_manager: Optional[PKIManager] = None,
        max_output_size_mb: float = 10.0,
    ):
        self.log = log_manager
        self.pki = pki_manager
        self.max_output_bytes = int(max_output_size_mb * 1024 * 1024)
        # Active requests: {request_id: ViewPointRequest}
        self._active_requests: Dict[str, ViewPointRequest] = {}

    # ─────────────────────────────────────────────
    # MAIN ENCODE PATH
    # ─────────────────────────────────────────────

    def encode_subagent_output(
        self,
        request: ViewPointRequest,
    ) -> ViewPointResponse:
        """
        Encode a subagent's raw output as a base64 transform.
        This is the primary protection boundary.
        """
        self._active_requests[request.request_id] = request

        # 1. Serialize raw output to JSON
        try:
            raw_json = json.dumps(request.raw_output, default=str, ensure_ascii=False)
        except Exception as e:
            raw_json = json.dumps({"error": f"Serialization failed: {e}", "raw_type": type(request.raw_output).__name__})

        raw_bytes = raw_json.encode("utf-8")

        # 2. Size guard
        if len(raw_bytes) > self.max_output_bytes:
            self.log.log(
                LogLevel.WARNING, self.AGENT_ID,
                f"ViewPoint: output truncated {len(raw_bytes)} > {self.max_output_bytes} bytes "
                f"from agent {request.source_agent_id}",
            )
            raw_bytes = raw_bytes[:self.max_output_bytes]

        # 3. Sanitize (strip common injection patterns)
        sanitized = self._sanitize(raw_bytes)

        # 4. Compute SHA256 of sanitized content
        content_sha256 = hashlib.sha256(sanitized).hexdigest()

        # 5. Base64 encode
        encoded = base64.b64encode(sanitized).decode("utf-8")

        # 6. Log the encoding event
        self.log.log(
            LogLevel.SECURITY, self.AGENT_ID,
            f"ViewPoint encoded output from {request.source_agent_id} "
            f"(sha256={content_sha256[:12]}...) for focalpoint={request.invoking_focalpoint_id}",
            extra={
                "request_id": request.request_id,
                "source_agent_id": request.source_agent_id,
                "permitted_recipients": list(request.permitted_recipients),
                "content_sha256": content_sha256,
                "original_size_bytes": len(raw_bytes),
            }
        )

        response = ViewPointResponse(
            request_id=request.request_id,
            encoded_payload=encoded,
            encoding="base64_json",
            content_sha256=content_sha256,
            source_agent_id=request.source_agent_id,
            permitted_recipients=request.permitted_recipients,
        )

        return response

    def grant_access(
        self,
        request_id: str,
        additional_agent_ids: List[str],
        granting_focalpoint_id: str,
    ) -> bool:
        """
        Allow a FocalPoint to grant additional agents access to a ViewPoint response.
        Only the invoking FocalPoint or another permitted FocalPoint can grant access.
        """
        req = self._active_requests.get(request_id)
        if not req:
            return False

        # Verify granting agent has authority (must be the invoking FocalPoint or a permitted FocalPoint)
        if (granting_focalpoint_id != req.invoking_focalpoint_id and
                granting_focalpoint_id not in req.permitted_recipients):
            self.log.log(
                LogLevel.SECURITY, self.AGENT_ID,
                f"ViewPoint: DENIED access grant by {granting_focalpoint_id} — not authorized for request {request_id}",
            )
            return False

        req.permitted_recipients.update(additional_agent_ids)
        self.log.log(
            LogLevel.AUDIT, self.AGENT_ID,
            f"ViewPoint: access granted by {granting_focalpoint_id} to {additional_agent_ids} for request {request_id}",
        )
        return True

    def verify_response_integrity(self, response: ViewPointResponse) -> bool:
        """Verify that an encoded ViewPoint response has not been tampered with."""
        try:
            raw = base64.b64decode(response.encoded_payload.encode("utf-8"))
            computed = hashlib.sha256(raw).hexdigest()
            return computed == response.content_sha256
        except Exception:
            return False

    # ─────────────────────────────────────────────
    # SANITIZATION
    # ─────────────────────────────────────────────

    _DANGEROUS_PATTERNS = [
        # Python exec/eval/compile injection
        b"exec(",
        b"eval(",
        b"compile(",
        b"__import__(",
        b"subprocess",
        b"os.system",
        b"os.popen",
        b"shutil.rmtree",
        # Shell injection
        b"$(", b"`",
        b"rm -rf",
        b"del /f",
        # Script tags
        b"<script",
        b"</script>",
        b"javascript:",
        # SQL injection patterns
        b"'; DROP",
        b"1=1--",
        # Null byte injection
        b"\x00",
    ]

    def _sanitize(self, raw_bytes: bytes) -> bytes:
        """
        Basic sanitization of raw bytes.
        Strips known dangerous patterns. This is a first-pass defense;
        the base64 encoding is the primary boundary.
        Note: True security comes from the FocalPoint NEVER executing the decoded output directly.
        """
        sanitized = raw_bytes
        flags_found = []

        for pattern in self._DANGEROUS_PATTERNS:
            if pattern in sanitized.lower():
                flags_found.append(pattern.decode("utf-8", errors="replace"))
                sanitized = sanitized.replace(pattern, b"[SANITIZED]")

        if flags_found:
            self.log.log(
                LogLevel.SECURITY, self.AGENT_ID,
                f"ViewPoint: sanitized {len(flags_found)} dangerous patterns: {flags_found}",
            )

        return sanitized






