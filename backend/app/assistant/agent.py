"""PydanticAI document agent definition."""

from __future__ import annotations

import json
import re
from pathlib import Path

from pydantic_ai import Agent, UsageLimits
from pydantic_ai.models.groq import GroqModel
from pydantic_ai.providers.groq import GroqProvider

from app.assistant.deps import DocumentAgentDeps
from app.assistant.outputs import GroundedAnswer
from app.assistant.status import emit_agent_done, emit_agent_start
from app.assistant.tools import (
    read_chunk,
    read_chunks,
    read_surrounding_chunks,
    search_filings,
)
from app.config import settings

_INSTRUCTIONS_PATH = Path(__file__).with_name("instructions.md")
INSTRUCTIONS = _INSTRUCTIONS_PATH.read_text(encoding="utf-8")

_document_agent: Agent[DocumentAgentDeps, str] | None = None


def get_document_agent() -> Agent[DocumentAgentDeps, str]:
    global _document_agent
    if _document_agent is None:
        model = GroqModel(
            settings.openai_model_name,
            provider=GroqProvider(api_key=settings.openai_api_key),
        )
        # Configure agent to return plain text to completely bypass Groq's complex final tool-wrapper deadlocks
        _document_agent = Agent(
            model,
            deps_type=DocumentAgentDeps,
            instructions=INSTRUCTIONS,
            tools=[search_filings, read_chunks, read_chunk, read_surrounding_chunks],
        )
    return _document_agent


def parse_grounded_answer_from_text(text: str) -> GroundedAnswer:
    """Safely extract and validate GroundedAnswer JSON from raw model text."""
    clean_text = text.strip()
    
    # Locate JSON boundaries even if the model wrapped it in markdown code blocks
    json_match = re.search(r"\{.*\}", clean_text, re.DOTALL)
    if json_match:
        clean_text = json_match.group(0)

    try:
        data = json.loads(clean_text)
        return GroundedAnswer.model_validate(data)
    except Exception as exc:
        raise ValueError(
            f"Failed to parse model output as valid GroundedAnswer JSON. "
            f"Error: {exc}. Please output raw JSON strictly matching the schema."
        )


async def run_document_agent(query: str, deps: DocumentAgentDeps) -> GroundedAnswer:
    emit_agent_start(deps, model=settings.openai_model_name)
    result = await get_document_agent().run(
        query,
        deps=deps,
        usage_limits=UsageLimits(request_limit=20),
    )
    emit_agent_done(deps)
    
    # Manually parse and validate the raw text output into our strict GroundedAnswer model
    return parse_grounded_answer_from_text(result.output)