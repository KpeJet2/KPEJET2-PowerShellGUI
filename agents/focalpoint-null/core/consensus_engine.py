# VersionTag: 2604.B2.V31.0
"""
ConsensusEngine — Cross-validation and result fusion for MultiModelDispatcher
Author: The Establishment
FileRole: Module

Scores N model responses by quality, structural integrity and peer agreement.
Selects the highest-confidence winner. Applies failover when winner confidence
falls below the configured threshold. Synthesises an agreement note when top-2
responses converge above the fusion threshold.

Scoring weights:
  Structure  40%  — rewards valid/near-valid JSON (FocalPoint expects JSON actions)
  Length     25%  — penalises empty/tiny responses and excessively verbose ones
  Agreement  25%  — Jaccard word-overlap agreement with all peer responses
  Weight     10%  — configured endpoint trust weight from focalpoint_config.yaml

Usage:
    engine = ConsensusEngine(log=log, failover_threshold=0.35)
    result = engine.evaluate(transaction)
    if result.all_failed:
        # fall back to primary single-model
    else:
        best_text = result.winner_text
"""
from __future__ import annotations

import json
import re
from typing import List

from core.log_manager import LogManager, LogLevel
from core.models import (
    ConsensusResult,
    DispatchTransaction,
    ModelResponse,
    ScoredResponse,
)

# Minimum confidence (0.0–1.0) to accept the winner without failover
DEFAULT_FAILOVER_THRESHOLD: float = 0.35

# Top-2 Jaccard similarity required before noting fusion agreement
SYNTHESIS_AGREEMENT_THRESHOLD: float = 0.40


class ConsensusEngine:
    """
    Multi-model response cross-validation and winner-selection engine.

    Receives a DispatchTransaction (output of MultiModelDispatcher.dispatch()),
    scores each successful response, selects the winner and returns a
    ConsensusResult with full audit metadata.

    Failover rule:
        If winner.confidence < failover_threshold AND there is a secondary
        candidate, the secondary is promoted and failover_applied is flagged.

    Fusion rule:
        If the top-2 responses agree at >= SYNTHESIS_AGREEMENT_THRESHOLD Jaccard
        similarity, fusion_applied is flagged and a note is added to fusion_notes.
    """

    AGENT_ID = "ConsensusEngine-00"

    def __init__(
        self,
        log: LogManager,
        failover_threshold: float = DEFAULT_FAILOVER_THRESHOLD,
    ) -> None:
        self.log = log
        self.failover_threshold = failover_threshold

    # ─────────────────────────────────────────────
    # PUBLIC: EVALUATE
    # ─────────────────────────────────────────────

    def evaluate(self, transaction: DispatchTransaction) -> ConsensusResult:
        """
        Evaluate all responses in a DispatchTransaction.
        Returns a ConsensusResult with the selected winner, scores, failover and fusion metadata.
        """
        successful = [
            r for r in transaction.responses
            if r.error is None and r.text
        ]

        if not successful:
            self.log.log(
                LogLevel.ERROR,
                self.AGENT_ID,
                f"All {len(transaction.responses)} endpoint(s) failed — "
                f"txn={transaction.transaction_id}",
                task_id=transaction.task_id,
            )
            return ConsensusResult(
                transaction_id=transaction.transaction_id,
                task_id=transaction.task_id,
                winner_endpoint_id="",
                winner_text="",
                confidence=0.0,
                all_failed=True,
                scored_responses=[],
                failover_applied=False,
                fusion_applied=False,
            )

        scored = self._score_responses(successful)
        scored.sort(key=lambda s: s.final_score, reverse=True)

        winner = scored[0]
        failover_applied = False
        fusion_applied = False
        fusion_notes: List[str] = []

        self.log.log(
            LogLevel.INFO,
            self.AGENT_ID,
            f"Consensus winner={winner.endpoint_id} "
            f"score={winner.final_score:.3f} confidence={winner.confidence:.3f} "
            f"txn={transaction.transaction_id}",
            task_id=transaction.task_id,
        )

        # Failover: low-confidence winner → promote secondary
        if winner.confidence < self.failover_threshold and len(scored) > 1:
            secondary = scored[1]
            self.log.log(
                LogLevel.WARNING,
                self.AGENT_ID,
                f"Failover triggered — winner confidence {winner.confidence:.3f} "
                f"< threshold {self.failover_threshold}. "
                f"Promoting secondary: {secondary.endpoint_id} "
                f"(score={secondary.final_score:.3f})",
                task_id=transaction.task_id,
            )
            winner = secondary
            failover_applied = True

        # Synthesis: check top-2 agreement
        if len(scored) > 1:
            sim = self._jaccard(scored[0].text, scored[1].text)
            if sim >= SYNTHESIS_AGREEMENT_THRESHOLD:
                fusion_applied = True
                fusion_notes.append(
                    f"Top-2 models ({scored[0].endpoint_id}, {scored[1].endpoint_id}) "
                    f"agree at {sim:.2f} Jaccard similarity — high consensus confidence."
                )
            else:
                fusion_notes.append(
                    f"Top-2 models diverge (Jaccard={sim:.2f}) — "
                    f"using primary winner only ({scored[0].endpoint_id})."
                )

        # Debug: log full score table
        for s in scored:
            self.log.log(
                LogLevel.DEBUG,
                self.AGENT_ID,
                f"  Score [{s.endpoint_id}] final={s.final_score:.3f} "
                f"len={s.length_score:.2f} struct={s.structure_score:.2f} "
                f"agree={s.agreement_score:.2f} w={s.weight:.2f} "
                f"latency={s.latency_ms}ms",
                task_id=transaction.task_id,
            )

        return ConsensusResult(
            transaction_id=transaction.transaction_id,
            task_id=transaction.task_id,
            winner_endpoint_id=winner.endpoint_id,
            winner_text=winner.text,
            confidence=winner.confidence,
            all_failed=False,
            scored_responses=scored,
            failover_applied=failover_applied,
            fusion_applied=fusion_applied,
            fusion_notes=fusion_notes,
        )

    # ─────────────────────────────────────────────
    # INTERNAL: SCORING
    # ─────────────────────────────────────────────

    def _score_responses(self, responses: List[ModelResponse]) -> List[ScoredResponse]:
        """Compute weighted quality scores for each successful ModelResponse."""
        scored: List[ScoredResponse] = []
        for resp in responses:
            length_score = self._score_length(resp.text)
            structure_score = self._score_structure(resp.text)

            # Agreement = mean Jaccard with all other peer responses
            peers = [r.text for r in responses if r.endpoint_id != resp.endpoint_id and r.text]
            if peers:
                agreement_score = sum(
                    self._jaccard(resp.text, peer) for peer in peers
                ) / len(peers)
            else:
                agreement_score = 0.5   # Single response — neutral

            weight_norm = min(max(resp.weight, 0.0), 1.0)

            # Weighted composite:  structure 40%  length 25%  agreement 25%  weight 10%
            final_score = (
                structure_score * 0.40
                + length_score * 0.25
                + agreement_score * 0.25
                + weight_norm * 0.10
            )
            # Confidence: square-root smoothing for better spread
            confidence = final_score ** 0.5

            scored.append(ScoredResponse(
                endpoint_id=resp.endpoint_id,
                text=resp.text,
                length_score=length_score,
                structure_score=structure_score,
                agreement_score=agreement_score,
                weight=weight_norm,
                final_score=final_score,
                confidence=confidence,
                latency_ms=resp.latency_ms,
            ))
        return scored

    @staticmethod
    def _score_length(text: str) -> float:
        """
        Score response length quality.
        Empty / tiny responses score near-zero. 200-4000 chars score 1.0.
        Very long responses are lightly penalised.
        """
        n = len(text)
        if n < 20:
            return 0.05
        if n < 80:
            return 0.35
        if n <= 4000:
            return 1.0
        if n <= 8000:
            return 0.85
        return 0.65

    @staticmethod
    def _score_structure(text: str) -> float:
        """
        Score structural quality of the response.
        FocalPoint-null expects JSON action directives — valid JSON scores highest.
        """
        stripped = text.strip()
        # Attempt to extract and parse a JSON object
        start = stripped.find("{")
        end = stripped.rfind("}") + 1
        if start >= 0 and end > start:
            try:
                json.loads(stripped[start:end])
                return 1.0      # Valid JSON block
            except (json.JSONDecodeError, ValueError):
                return 0.70     # Has braces but not valid JSON
        # Has recognised JSON field keys
        if re.search(
            r'"(action|assigned_to|task_title|reasoning|directive|options)"\s*:',
            text,
        ):
            return 0.60
        # Markdown structure (headers, bullet points)
        if re.search(r'^#+\s|^\s*[-*]\s', text, re.MULTILINE):
            return 0.40
        # Plain prose
        return 0.20

    @staticmethod
    def _jaccard(text_a: str, text_b: str) -> float:
        """
        Compute Jaccard word-overlap similarity between two response texts.
        Uses words of 3+ characters to reduce noise from connective words.
        """
        if not text_a or not text_b:
            return 0.0
        words_a = set(re.findall(r'\b\w{3,}\b', text_a.lower()))
        words_b = set(re.findall(r'\b\w{3,}\b', text_b.lower()))
        if not words_a or not words_b:
            return 0.0
        intersection = words_a & words_b
        union = words_a | words_b
        return len(intersection) / len(union)
