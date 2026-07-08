"""PydanticAI document agent definition."""

from __future__ import annotations

from pathlib import Path
import re
from pydantic_ai import Agent, UsageLimits
from pydantic_ai.models.groq import GroqModel
from pydantic_ai.providers.groq import GroqProvider

from app.assistant.deps import DocumentAgentDeps
from app.assistant.outputs import GroundedAnswer
from app.assistant.status import emit_agent_done, emit_agent_start
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
        # Bypassing tool bindings completely on open-weights model to ensure 100% stability on Groq
        _document_agent = Agent(
            model,
            deps_type=DocumentAgentDeps,
            instructions=INSTRUCTIONS,
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
        import json
        data = json.loads(clean_text)
        return GroundedAnswer.model_validate(data)
    except Exception as exc:
        raise ValueError(
            f"Failed to parse model output as valid GroundedAnswer JSON. "
            f"Error: {exc}. Please output raw JSON strictly matching the schema."
        )


async def run_document_agent(query: str, context_text: str, deps: DocumentAgentDeps) -> GroundedAnswer:
    """Execute the document research agent with injected database context."""
    emit_agent_start(deps, model=settings.openai_model_name)
    
    # Bundle raw database chunks directly into the model request prompt
    prompt = (
        f"User Analyst Query: {query}\n\n"
        f"Retrieved SEC Filing Source Passages (Grounding Context):\n"
        f"==================================================\n"
        f"{context_text}\n"
        f"==================================================\n\n"
        f"Generate your citable answer using only these retrieved source chunks."
    )
    
    result = await get_document_agent().run(
        prompt,
        deps=deps,
        usage_limits=UsageLimits(request_limit=10),
    )
    emit_agent_done(deps)
    return parse_grounded_answer_from_text(result.output)