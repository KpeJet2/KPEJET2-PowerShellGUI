# VersionTag: 2604.B0.v1
# VersionTag: 2604.B0.v1
# VersionTag: 2604.B0.v1
# VersionTag: 2604.B0.v1
"""
FocalPoint-null Compatibility Shim
Applies necessary monkey-patches to fix known upstream library incompatibilities.
Import this module FIRST in main.py before importing agent_framework.

Known issue:
- agent-framework-core 1.0.0b260107 references SpanAttributes.LLM_REQUEST_MODEL
  from opentelemetry-semantic-conventions-ai 0.4.x which removed that attribute.
  Patch: add LLM_REQUEST_MODEL as a constant matching the expected gen_ai convention.
"""
from __future__ import annotations

import importlib
import sys

def apply_patches() -> None:
    """Apply all compatibility patches. Call before importing agent_framework."""
    _patch_otel_span_attributes()


def _patch_otel_span_attributes() -> None:
    """
    Patch opentelemetry.semconv_ai.SpanAttributes to add LLM_REQUEST_MODEL
    if it is missing. This attribute was removed in opentelemetry-semantic-
    conventions-ai 0.4.x but agent-framework 1.0.0b260107 still references it.
    """
    try:
        from opentelemetry.semconv_ai import SpanAttributes
        if not hasattr(SpanAttributes, "LLM_REQUEST_MODEL"):
            # Use the gen_ai request model attribute as the replacement value
            SpanAttributes.LLM_REQUEST_MODEL = "gen_ai.request.model"
    except ImportError:
        pass  # Package not installed — agent_framework will fail later with a clear error

    # Also patch LLM_REQUEST_MAX_TOKENS and LLM_REQUEST_TEMPERATURE if missing
    try:
        from opentelemetry.semconv_ai import SpanAttributes
        if not hasattr(SpanAttributes, "LLM_REQUEST_MAX_TOKENS"):
            SpanAttributes.LLM_REQUEST_MAX_TOKENS = "gen_ai.request.max_tokens"
        if not hasattr(SpanAttributes, "LLM_REQUEST_TEMPERATURE"):
            SpanAttributes.LLM_REQUEST_TEMPERATURE = "gen_ai.request.temperature"
        if not hasattr(SpanAttributes, "LLM_REQUEST_TOP_P"):
            SpanAttributes.LLM_REQUEST_TOP_P = "gen_ai.request.top_p"
        if not hasattr(SpanAttributes, "LLM_USAGE_PROMPT_TOKENS"):
            SpanAttributes.LLM_USAGE_PROMPT_TOKENS = "gen_ai.usage.input_tokens"
        if not hasattr(SpanAttributes, "LLM_USAGE_COMPLETION_TOKENS"):
            SpanAttributes.LLM_USAGE_COMPLETION_TOKENS = "gen_ai.usage.output_tokens"
        if not hasattr(SpanAttributes, "LLM_RESPONSE_MODEL"):
            SpanAttributes.LLM_RESPONSE_MODEL = "gen_ai.response.model"
        if not hasattr(SpanAttributes, "LLM_SYSTEM"):
            SpanAttributes.LLM_SYSTEM = "gen_ai.system"
    except ImportError:
        pass






