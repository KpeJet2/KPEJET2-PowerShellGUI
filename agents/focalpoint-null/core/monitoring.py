# VersionTag: 2605.B5.V46.0
# VersionTag: 2605.B5.V46.0
# VersionTag: 2605.B5.V46.0
# VersionTag: 2605.B5.V46.0
from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timezone
from threading import Lock
from typing import Dict, Optional


def _iso(ts: Optional[datetime]) -> Optional[str]:
    if ts is None:
        return None
    return ts.astimezone(timezone.utc).isoformat()


def _duration(seconds: float) -> str:
    total = max(0, int(seconds))
    hours, rem = divmod(total, 3600)
    mins, secs = divmod(rem, 60)
    return f"{hours:02d}:{mins:02d}:{secs:02d}"


@dataclass
class AgentRuntimeState:
    agent_id: str
    endpoint_url: str
    started_at: datetime = field(default_factory=lambda: datetime.now(timezone.utc))
    last_received_at: Optional[datetime] = None
    last_sent_at: Optional[datetime] = None
    last_error_at: Optional[datetime] = None
    error_count: int = 0
    last_error_message: str = ""
    active_processing: bool = False
    active_started_at: Optional[datetime] = None
    total_active_seconds: float = 0.0
    received_count: int = 0
    sent_count: int = 0

    def start_processing(self) -> None:
        if not self.active_processing:
            self.active_processing = True
            self.active_started_at = datetime.now(timezone.utc)

    def stop_processing(self) -> None:
        if self.active_processing and self.active_started_at:
            elapsed = (datetime.now(timezone.utc) - self.active_started_at).total_seconds()
            self.total_active_seconds += max(0.0, elapsed)
        self.active_processing = False
        self.active_started_at = None

    def snapshot(self) -> Dict:
        now = datetime.now(timezone.utc)
        uptime_seconds = (now - self.started_at).total_seconds()
        current_active_seconds = 0.0
        if self.active_processing and self.active_started_at:
            current_active_seconds = (now - self.active_started_at).total_seconds()

        total_active = self.total_active_seconds + current_active_seconds

        status = "idle"
        if self.active_processing:
            status = "active"
        elif self.error_count > 0 and self.last_error_at and self.last_sent_at:
            if self.last_error_at >= self.last_sent_at:
                status = "error"

        return {
            "agent_id": self.agent_id,
            "status": status,
            "endpoint_url": self.endpoint_url,
            "last_received_at": _iso(self.last_received_at),
            "last_sent_at": _iso(self.last_sent_at),
            "error_count": self.error_count,
            "last_error_message": self.last_error_message,
            "last_error_at": _iso(self.last_error_at),
            "uptime_seconds": round(uptime_seconds, 3),
            "uptime_hms": _duration(uptime_seconds),
            "active_processing": self.active_processing,
            "active_processing_seconds": round(total_active, 3),
            "active_processing_hms": _duration(total_active),
            "received_count": self.received_count,
            "sent_count": self.sent_count,
        }


class RuntimeMonitor:
    def __init__(self) -> None:
        self._lock = Lock()
        self._states: Dict[str, AgentRuntimeState] = {}
        self.started_at = datetime.now(timezone.utc)

    def register_agent(self, agent_id: str, endpoint_url: str) -> None:
        with self._lock:
            if agent_id in self._states:
                self._states[agent_id].endpoint_url = endpoint_url
                return
            self._states[agent_id] = AgentRuntimeState(agent_id=agent_id, endpoint_url=endpoint_url)

    def mark_received(self, agent_id: str) -> None:
        with self._lock:
            st = self._states.get(agent_id)
            if not st:
                return
            st.received_count += 1
            st.last_received_at = datetime.now(timezone.utc)

    def mark_sent(self, agent_id: str) -> None:
        with self._lock:
            st = self._states.get(agent_id)
            if not st:
                return
            st.sent_count += 1
            st.last_sent_at = datetime.now(timezone.utc)

    def mark_error(self, agent_id: str, message: str) -> None:
        with self._lock:
            st = self._states.get(agent_id)
            if not st:
                return
            st.error_count += 1
            st.last_error_at = datetime.now(timezone.utc)
            st.last_error_message = message[:500]

    def start_processing(self, agent_id: str) -> None:
        with self._lock:
            st = self._states.get(agent_id)
            if not st:
                return
            st.start_processing()

    def stop_processing(self, agent_id: str) -> None:
        with self._lock:
            st = self._states.get(agent_id)
            if not st:
                return
            st.stop_processing()

    def snapshot(self) -> Dict:
        with self._lock:
            agent_states = [s.snapshot() for s in self._states.values()]

        now = datetime.now(timezone.utc)
        app_uptime_seconds = (now - self.started_at).total_seconds()
        return {
            "generated_at": _iso(now),
            "app_started_at": _iso(self.started_at),
            "app_uptime_seconds": round(app_uptime_seconds, 3),
            "app_uptime_hms": _duration(app_uptime_seconds),
            "agents": sorted(agent_states, key=lambda x: x["agent_id"]),
        }







