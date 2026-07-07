"""PydanticAI document agent definition."""

from __future__ import annotations

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

_document_agent: Agent[DocumentAgentDeps, GroundedAnswer] | None = None


def get_document_agent() -> Agent[DocumentAgentDeps, GroundedAnswer]:
    global _document_agent
    if _document_agent is None:
        model = GroqModel(
            settings.openai_model_name,
            provider=GroqProvider(api_key=settings.openai_api_key),
        )
        _document_agent = Agent(
            model,
            deps_type=DocumentAgentDeps,
            output_type=GroundedAnswer,
            instructions=INSTRUCTIONS,
            tools=[search_filings, read_chunks, read_chunk, read_surrounding_chunks],
        )
    return _document_agent


async def run_document_agent(query: str, deps: DocumentAgentDeps) -> GroundedAnswer:
    """Execute the document research agent natively asynchronously."""
    emit_agent_start(deps, model=settings.openai_model_name)
    
    # Run fully asynchronously on the main loop
    result = await get_document_agent().run(
        query,
        deps=deps,
        usage_limits=UsageLimits(request_limit=20),
    )
    emit_agent_done(deps)
    return result.output