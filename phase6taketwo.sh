uv run python -c "
from pathlib import Path

# Create directories
Path('backend/app/assistant').mkdir(parents=True, exist_ok=True)
Path('backend/app/grounding').mkdir(parents=True, exist_ok=True)

# 1. Write app/assistant/instructions.md
Path('backend/app/assistant/instructions.md').write_text('''You are Document Copilot, an internal SEC filing research assistant for equity analysts.

## Product contract

- Answer **only** from passages returned by your tools (`search_filings`, `read_chunks`, `read_chunk`, `read_surrounding_chunks`). Never invent facts, numbers, or filing language.
- **Cite every factual claim** with `[n]` markers in the answer text that match `citation_index` in your citations list.
- Each citation must include a **verbatim excerpt** copied from the retrieved chunk text.
- If the corpus does not contain enough evidence, set `insufficient_evidence` to true, explain what is missing, and return an **empty** citations list. Do not fabricate citations.
- **No stock picks**, trading recommendations, or investment advice.
- Do not infer causation or conclusions beyond what the filings explicitly state (e.g. do not claim generative AI improved margins unless a filing directly says so).
- Keep answers concise and analyst-friendly. Prefer direct quotes in excerpt fields.

## Corpus scope

- SEC 10-K and 10-Q filings for S&P 500 companies, fiscal years 2020–2025.
- The pilot corpus includes 10-K filings for AAPL, AMZN, GOOGL, MSFT, and NVDA across fiscal years 2021–2025.

## Tool usage

1. Start with `search_filings` using the analyst's question. Add `ticker`, `form`, or `fiscal_years` filters when the question names a company or period. Results already include 800-character excerpts **and** neighboring chunks — use those first.
2. Prefer `read_chunks` when you need full text for multiple chunk IDs. Pass every ID in **one** call instead of many separate `read_chunk` calls.
3. Use `read_chunk` only for a single chunk when `read_chunks` is not appropriate.
4. Use `read_surrounding_chunks` only when search excerpts are insufficient and you need more adjacent context than neighbors already returned.
5. **Minimize tool rounds.** Avoid re-fetching chunks already shown in `search_filings` output. Batch reads and answer as soon as you have enough evidence.

## Output format

Return a structured `GroundedAnswer`:
- `answer`: your response with `[1]`, `[2]`, etc. inline
- `citations`: list of `{citation_index, chunk_id, excerpt}` for each cited claim
- `insufficient_evidence`: true only when you cannot answer from retrieved passages

Only include citation entries that are referenced in the answer text. Each `excerpt` must be copied exactly from one retrieved chunk; do not rewrite, merge, or clean up table text before placing it in the excerpt field.''', encoding='utf-8')

# 2. Write app/assistant/outputs.py
Path('backend/app/assistant/outputs.py').write_text('''\"\"\"Structured output types for the document agent.\"\"\"

from __future__ import annotations

import uuid
from pydantic import BaseModel, Field


class Citation(BaseModel):
    citation_index: int = Field(
        description=\"1-based index referenced as [n] in the answer text\"
    )
    chunk_id: uuid.UUID = Field(description=\"UUID of the cited document chunk\")
    excerpt: str = Field(
        description=\"Verbatim substring from the chunk text supporting the claim\"
    )


class GroundedAnswer(BaseModel):
    answer: str = Field(description=\"Plain-English answer with [n] citation markers\")
    citations: list[Citation] = Field(
        default_factory=list,
        description=\"Citations backing factual claims in the answer\",
    )
    insufficient_evidence: bool = Field(
        default=False,
        description=\"True when the corpus does not contain enough evidence to answer\",
    )''', encoding='utf-8')

# 3. Write app/assistant/deps.py
Path('backend/app/assistant/deps.py').write_text('''\"\"\"Runtime dependencies for the document agent.\"\"\"

from __future__ import annotations

import uuid
from collections.abc import Callable
from dataclasses import dataclass, field

from app.retrieval.retriever import DocumentRetriever
from app.retrieval.types import RetrievedPassage

StatusCallback = Callable[[str, str], None]


@dataclass
class TurnRegistry:
    \"\"\"Tracks every chunk retrieved during a turn — the citation allowlist.\"\"\"

    passages_by_chunk_id: dict[uuid.UUID, RetrievedPassage] = field(default_factory=dict)

    def register(self, passage: RetrievedPassage) -> None:
        self.passages_by_chunk_id[passage.chunk_id] = passage
        for neighbor in passage.neighbors:
            self.passages_by_chunk_id[neighbor.chunk_id] = neighbor

    def register_many(self, passages: list[RetrievedPassage]) -> None:
        for passage in passages:
            self.register(passage)


@dataclass
class DocumentAgentDeps:
    retriever: DocumentRetriever
    registry: TurnRegistry
    thread_id: uuid.UUID
    user_id: uuid.UUID
    on_status: StatusCallback | None = None

    def emit_status(self, stage: str, message: str) -> None:
        if self.on_status is not None:
            self.on_status(stage, message)''', encoding='utf-8')

# 4. Write app/assistant/status.py
Path('backend/app/assistant/status.py').write_text('''\"\"\"Map internal agent/tool events to analyst-friendly pipeline status.\"\"\"

from __future__ import annotations

from app.assistant.deps import DocumentAgentDeps


def emit_tool_start(deps: DocumentAgentDeps, name: str, detail: str) -> None:
    stage, message = _tool_start_status(name, detail)
    deps.emit_status(stage, message)


def emit_agent_start(deps: DocumentAgentDeps, *, model: str) -> None:
    deps.emit_status(\"analyzing\", \"Analyzing your question…\")


def emit_agent_done(deps: DocumentAgentDeps) -> None:
    deps.emit_status(\"verifying\", \"Verifying citations…\")


def _tool_start_status(name: str, detail: str) -> tuple[str, str]:
    if name == \"search_filings\":
        suffix = f\" ({detail})\" if detail != \"no filters\" else \"\"
        return \"searching\", f\"Searching SEC filings...{suffix}\"
    if name == \"read_surrounding_chunks\":
        return \"reading\", \"Reading surrounding context…\"
    if name in {\"read_chunk\", \"read_chunks\"}:
        return \"reading\", \"Reading source passages…\"
    return \"reading\", \"Reading source documents…\"''', encoding='utf-8')

# 5. Write app/assistant/tools.py
Path('backend/app/assistant/tools.py').write_text('''\"\"\"Bounded agent tools over the retrieval layer.\"\"\"

from __future__ import annotations

import asyncio
import functools
import uuid
from pydantic_ai import RunContext

from app.assistant.deps import DocumentAgentDeps
from app.assistant.status import emit_tool_start
from app.database.documents import (
    get_chunk_with_document,
    get_chunks_by_ids,
    get_surrounding_chunks,
)
from app.database.models import DocumentChunk, SourceDocument
from app.database.session import get_session
from app.retrieval.types import RetrievedPassage, SearchFilters, format_passages_for_agent


def _passage_from_chunk(
    chunk: DocumentChunk,
    document: SourceDocument,
    *,
    fusion_score: float = 0.0,
) -> RetrievedPassage:
    return RetrievedPassage(
        chunk_id=chunk.id,
        document_id=chunk.source_document_id,
        chunk_index=chunk.chunk_index,
        text=chunk.content,
        page=chunk.page,
        section=chunk.section,
        fusion_score=fusion_score,
        ticker=document.ticker,
        company_name=document.company_name,
        form=document.form,
        filing_date=document.filing_date,
        fiscal_year=document.filing_date.year,
        accession_number=document.accession_number,
        neighbors=[],
    )


def _parse_fiscal_years(raw: str | None) -> list[int] | None:
    if not raw:
        return None
    years = [int(part.strip()) for part in raw.split(\",\") if part.strip()]
    return years or None


def _search_sync(
    deps: DocumentAgentDeps,
    query: str,
    *,
    ticker: str | None,
    form: str | None,
    fiscal_years: str | None,
) -> list[RetrievedPassage]:
    filters = SearchFilters(
        ticker=ticker,
        form=form,
        fiscal_years=_parse_fiscal_years(fiscal_years),
    )
    return deps.retriever.search(query, filters=filters)


def _read_chunks_sync(
    deps: DocumentAgentDeps,
    chunk_ids: list[uuid.UUID],
) -> list[RetrievedPassage]:
    with get_session() as session:
        chunks_by_id = get_chunks_by_ids(session, chunk_ids)
        passages: list[RetrievedPassage] = []
        for chunk_id in chunk_ids:
            chunk = chunks_by_id.get(chunk_id)
            if chunk is None or chunk.source_document is None:
                continue
            passages.append(_passage_from_chunk(chunk, chunk.source_document))
        return passages


def _read_surrounding_sync(
    deps: DocumentAgentDeps,
    chunk_id: uuid.UUID,
    radius: int,
) -> list[RetrievedPassage]:
    with get_session() as session:
        anchor = get_chunk_with_document(session, chunk_id)
        if anchor is None:
            return []
        anchor_chunk, _ = anchor
        neighbor_chunks = get_surrounding_chunks(session, chunk_id, radius)
        passages: list[RetrievedPassage] = []
        for neighbor_chunk in neighbor_chunks:
            if neighbor_chunk.source_document is None:
                continue
            passages.append(
                _passage_from_chunk(neighbor_chunk, neighbor_chunk.source_document)
            )
        if anchor_chunk.source_document is not None:
            passages.insert(
                0,
                _passage_from_chunk(anchor_chunk, anchor_chunk.source_document),
            )
        return passages


async def _run_tool(
    deps: DocumentAgentDeps,
    name: str,
    detail: str,
    fn,
    /,
    *args,
    **kwargs,
):
    emit_tool_start(deps, name, detail)
    return await asyncio.to_thread(functools.partial(fn, *args, **kwargs))


async def search_filings(
    ctx: RunContext[DocumentAgentDeps],
    query: str,
    ticker: str | None = None,
    form: str | None = None,
    fiscal_years: str | None = None,
) -> str:
    \"\"\"Search SEC filings with hybrid retrieval. Optional filters: ticker, form, fiscal_years (comma-separated).\"\"\"
    filter_bits = [
        bit
        for bit in (
            f\"ticker={ticker}\" if ticker else None,
            f\"form={form}\" if form else None,
            f\"fiscal_years={fiscal_years}\" if fiscal_years else None,
        )
        if bit
    ]
    detail = \", \".join(filter_bits) if filter_bits else \"no filters\"
    passages = await _run_tool(
        ctx.deps,
        \"search_filings\",
        detail,
        _search_sync,
        ctx.deps,
        query,
        ticker=ticker,
        form=form,
        fiscal_years=fiscal_years,
    )
    ctx.deps.registry.register_many(passages)
    return format_passages_for_agent(passages)


async def read_chunk(ctx: RunContext[DocumentAgentDeps], chunk_id: str) -> str:
    \"\"\"Read the full text of a specific document chunk by UUID.\"\"\"
    try:
        parsed_id = uuid.UUID(chunk_id)
    except ValueError:
        return f\"Error: invalid chunk_id {chunk_id!r}.\"

    passage = await _run_tool(
        ctx.deps,
        \"read_chunk\",
        f\"chunk_id={chunk_id}\",
        _read_chunk_sync,
        ctx.deps,
        parsed_id,
    )
    if passage:
        ctx.deps.registry.register(passage)
        return format_passages_for_agent([passage])
    return f\"Error: chunk {chunk_id} not found.\"


def _read_chunk_sync(deps: DocumentAgentDeps, chunk_id: uuid.UUID) -> RetrievedPassage | None:
    from app.database.documents import get_chunk_with_document
    from app.database.session import get_session
    with get_session() as session:
        res = get_chunk_with_document(session, chunk_id)
        if res is None:
            return None
        chunk, document = res
        return _passage_from_chunk(chunk, document, fusion_score=0.0)


async def read_chunks(ctx: RunContext[DocumentAgentDeps], chunk_ids: list[str]) -> str:
    \"\"\"Read the full text of multiple document chunks in one call.\"\"\"
    parsed_ids: list[uuid.UUID] = []
    for chunk_id in chunk_ids:
        try:
            parsed_ids.append(uuid.UUID(chunk_id))
        except ValueError:
            return f\"Error: invalid chunk_id {chunk_id!r}.\"

    if not parsed_ids:
        return \"Error: chunk_ids must include at least one UUID.\"

    passages = await _run_tool(
        ctx.deps,
        \"read_chunks\",
        f\"count={len(parsed_ids)}\",
        _read_chunks_sync,
        ctx.deps,
        parsed_ids,
    )
    if not passages:
        return \"Error: none of the requested chunks were found.\"

    ctx.deps.registry.register_many(passages)
    return format_passages_for_agent(passages)


async def read_surrounding_chunks(
    ctx: RunContext[DocumentAgentDeps],
    chunk_id: str,
    radius: int | None = None,
) -> str:
    \"\"\"Read chunks before and after a given chunk within the same filing.\"\"\"
    try:
        parsed_id = uuid.UUID(chunk_id)
    except ValueError:
        return f\"Error: invalid chunk_id {chunk_id!r}.\"

    resolved_radius = (
        radius if radius is not None else 1
    )
    if resolved_radius < 1:
        return \"Error: radius must be 1 or greater.\"

    passages = await _run_tool(
        ctx.deps,
        \"read_surrounding_chunks\",
        f\"chunk_id={chunk_id} radius={resolved_radius}\",
        _read_surrounding_sync,
        ctx.deps,
        parsed_id,
        resolved_radius,
    )
    if not passages:
        return f\"Error: chunk {chunk_id} not found.\"

    ctx.deps.registry.register_many(passages)
    return format_passages_for_agent(passages)''', encoding='utf-8')

# 6. Write app/assistant/agent.py
Path('backend/app/assistant/agent.py').write_text('''\"\"\"PydanticAI document agent definition.\"\"\"

from __future__ import annotations

from pathlib import Path

from pydantic_ai import Agent, UsageLimits
from pydantic_ai.models.openai import OpenAIChatModel
from pydantic_ai.providers.openai import OpenAIProvider

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

_INSTRUCTIONS_PATH = Path(__file__).with_name(\"instructions.md\")
INSTRUCTIONS = _INSTRUCTIONS_PATH.read_text(encoding=\"utf-8\")

_document_agent: Agent[DocumentAgentDeps, GroundedAnswer] | None = None


def get_document_agent() -> Agent[DocumentAgentDeps, GroundedAnswer]:
    global _document_agent
    if _document_agent is None:
        model = OpenAIChatModel(
            settings.openai_model_name,
            provider=OpenAIProvider(api_key=settings.openai_api_key),
        )
        _document_agent = Agent(
            model,
            deps_type=DocumentAgentDeps,
            output_type=GroundedAnswer,
            instructions=INSTRUCTIONS,
            tools=[search_filings, read_chunks, read_chunk, read_surrounding_chunks],
        )
    return _document_agent


def run_document_agent(query: str, deps: DocumentAgentDeps) -> GroundedAnswer:
    emit_agent_start(deps, model=settings.openai_model_name)
    result = get_document_agent().run_sync(
        query,
        deps=deps,
        usage_limits=UsageLimits(request_limit=20),
    )
    emit_agent_done(deps)
    return result.output''', encoding='utf-8')

# 7. Write app/grounding/validator.py
Path('backend/app/grounding/validator.py').write_text('''\"\"\"Fail-closed citation validation against the turn registry.\"\"\"

from __future__ import annotations

import asyncio
import json
import re
from dataclasses import dataclass
from typing import Any

from openai import OpenAI
from pydantic import BaseModel, Field

from app.assistant.deps import TurnRegistry
from app.assistant.outputs import GroundedAnswer
from app.config import settings

_CITATION_MARKER_RE = re.compile(r\"\\[(\\d+)\\]\")

_GROUNDING_JUDGE_SYSTEM_PROMPT = \"\"\"\\
You are a strict grounding validator for SEC filing answers.
Your task is to decide whether each answer claim identified by a citation marker is supported by the retrieved source chunk for that citation.

You must return a JSON object containing a \"decisions\" array. Each item inside \"decisions\" must be a JSON object with:
- \"citation_index\": int (matching the case citation_index)
- \"supported\": bool (true if fully supported, false if partial, ambiguous, or absent)
- \"reason\": str (short reason for the grounding decision)

Strictly output valid JSON matching this schema:
{
  \"decisions\": [
    {
      \"citation_index\": 1,
      \"supported\": true,
      \"reason\": \"...\"
    }
  ]
}
\"\"\"


@dataclass(frozen=True, slots=True)
class ValidationResult:
    ok: bool
    error: str | None = None


class CitationGroundingCase(BaseModel):
    citation_index: int
    answer: str
    excerpt: str
    source_text: str


class CitationGroundingDecision(BaseModel):
    citation_index: int
    supported: bool
    reason: str


class GroundingValidator:
    def __init__(self) -> None:
        self._client = OpenAI(api_key=settings.openai_api_key)

    async def validate(
        self,
        answer: GroundedAnswer,
        registry: TurnRegistry,
    ) -> ValidationResult:
        if not answer.answer.strip():
            return ValidationResult(ok=False, error=\"Answer text is empty.\")

        if answer.insufficient_evidence:
            if answer.citations:
                return ValidationResult(
                    ok=False,
                    error=\"insufficient_evidence answers must not include citations.\",
                )
            return ValidationResult(ok=True)

        if not answer.citations:
            return ValidationResult(
                ok=False,
                error=\"Grounded answers must include at least one citation.\",
            )

        if not registry.passages_by_chunk_id:
            return ValidationResult(
                ok=False,
                error=\"Citations present but no passages were retrieved this turn.\",
            )

        indices = [citation.citation_index for citation in answer.citations]
        if len(indices) != len(set(indices)):
            return ValidationResult(ok=False, error=\"Duplicate citation_index values.\")

        expected_indices = list(range(1, len(indices) + 1))
        if sorted(indices) != expected_indices:
            return ValidationResult(
                ok=False,
                error=\"citation_index values must be unique, 1-based, and contiguous.\",
            )

        marker_indices = {int(m.group(1)) for m in _CITATION_MARKER_RE.finditer(answer.answer)}
        if marker_indices != set(indices):
            return ValidationResult(
                ok=False,
                error=\"Answer [n] markers must match citation_index values exactly.\",
            )

        cases: list[CitationGroundingCase] = []
        for citation in answer.citations:
            passage = registry.passages_by_chunk_id.get(citation.chunk_id)
            if passage is None:
                return ValidationResult(
                    ok=False,
                    error=f\"Citation references chunk {citation.chunk_id} that was not retrieved.\",
                )

            # Verbatim case-insensitive substring verification
            excerpt_clean = \" \".join(citation.excerpt.lower().split())
            source_clean = \" \".join(passage.text.lower().split())
            if excerpt_clean not in source_clean:
                return ValidationResult(
                    ok=False,
                    error=f\"Citation [{citation.citation_index}] excerpt is not a verbatim substring of the cited source chunk.\"
                )

            cases.append(
                CitationGroundingCase(
                    citation_index=citation.citation_index,
                    answer=answer.answer,
                    excerpt=citation.excerpt,
                    source_text=passage.text,
                )
            )

        try:
            decisions = await asyncio.to_thread(self._judge_sync, cases)
        except Exception as exc:
            return ValidationResult(
                ok=False,
                error=f\"Grounding judge failed: {exc}\",
            )

        decision_by_index = {d[\"citation_index\"]: d for d in decisions}
        for citation_index in indices:
            decision = decision_by_index.get(citation_index)
            if not decision:
                return ValidationResult(
                    ok=False,
                    error=f\"Missing decision for citation index {citation_index}.\",
                )
            if not decision.get(\"supported\"):
                return ValidationResult(
                    ok=False,
                    error=(
                        f\"Citation [{citation_index}] is not supported by retrieved \"
                        f\"source text: {decision.get('reason')}\"
                    ),
                )

        return ValidationResult(ok=True)

    def _judge_sync(self, cases: list[CitationGroundingCase]) -> list[dict[str, Any]]:
        response = self._client.chat.completions.create(
            model=settings.openai_model_name,
            temperature=0,
            response_format={\"type\": \"json_object\"},
            messages=[
                {\"role\": \"system\", \"content\": _GROUNDING_JUDGE_SYSTEM_PROMPT},
                {
                    \"role\": \"user\",
                    \"content\": json.dumps(
                        {\"cases\": [case.model_dump(mode=\"json\") for case in cases]},
                        separators=(\",\", \":\"),
                    ),
                },
            ],
        )
        payload = json.loads(response.choices[0].message.content or \"{}\")
        return payload.get(\"decisions\", [])


def prune_unreferenced_citations(answer: GroundedAnswer) -> GroundedAnswer:
    marker_indices = {int(m.group(1)) for m in _CITATION_MARKER_RE.finditer(answer.answer)}
    if not marker_indices:
        return answer
    citations = [c for c in answer.citations if c.citation_index in marker_indices]
    if len(citations) == len(answer.citations):
        return answer
    return answer.model_copy(update={\"citations\": citations})'''.replace('atob', 'openMobile')
# Correct minor formatting replacement artifacts from the previous CLI
Path('backend/app/grounding/validator.py').write_text(Path('backend/app/grounding/validator.py').read_text(encoding='utf-8'), encoding='utf-8')

# 8. Write app/chat/streaming.py
Path('backend/app/chat/streaming.py').write_text('''\"\"\"AI SDK-compatible SSE streaming for grounded assistant replies.\"\"\"

from __future__ import annotations

import json
import uuid
from collections.abc import AsyncIterator
from supabase import AsyncClient

from app.assistant.deps import TurnRegistry
from app.assistant.outputs import GroundedAnswer
from app.chat.messages import build_assistant_message
from app.database.chats import append_grounded_turn
from app.grounding.validator import ValidationResult
from app.schemas.chat import CitationPart, StatusPart, StatusPayload, UIMessage

GROUNDING_FAILURE_MESSAGE = (
    \"I found relevant source passages, but I could not fully verify the answer \"
    \"against them. Try asking a narrower question or breaking it into smaller parts.\"
)


def sse_event(payload: dict[str, object]) -> str:
    return f\"data: {json.dumps(payload, separators=(',', ':'), default=str)}\\n\\n\"


async def stream_status(stage: str, message: str) -> AsyncIterator[str]:
    part = StatusPart(data=StatusPayload(stage=stage, message=message))
    yield sse_event(part.model_dump(by_alias=True, mode=\"json\"))


async def _text_events(text: str, *, message_id: str) -> AsyncIterator[str]:
    yield sse_event({\"type\": \"text-start\", \"id\": message_id})
    for word in text.split(\" \"):
        yield sse_event({\"type\": \"text-delta\", \"id\": message_id, \"delta\": f\"{word} \"})
    yield sse_event({\"type\": \"text-end\", \"id\": message_id})


async def _citation_events(citation_parts: list[CitationPart]) -> AsyncIterator[str]:
    for part in citation_parts:
        yield sse_event(part.model_dump(by_alias=True, mode=\"json\"))


async def stream_grounded_answer(
    answer: GroundedAnswer,
    registry: TurnRegistry,
    *,
    message_id: str,
) -> AsyncIterator[str]:
    yield sse_event({\"type\": \"start\", \"messageId\": message_id})

    async for event in _text_events(answer.answer, message_id=message_id):
        yield event

    assistant_message = build_assistant_message(answer, registry, message_id=uuid.UUID(message_id))
    citation_parts = [p for p in assistant_message.parts if isinstance(p, CitationPart)]
    async for event in _citation_events(citation_parts):
        yield event

    yield sse_event({\"type\": \"finish\"})


async def stream_error(error_text: str) -> AsyncIterator[str]:
    yield sse_event({\"type\": \"error\", \"errorText\": error_text})


async def stream_grounded_turn_and_persist(
    *,
    client: AsyncClient,
    thread_id: uuid.UUID,
    user_message: UIMessage,
    thread_title: str,
    answer: GroundedAnswer,
    registry: TurnRegistry,
    validation: ValidationResult,
) -> AsyncIterator[str]:
    if not validation.ok:
        async for event in stream_error(GROUNDING_FAILURE_MESSAGE):
            yield event
        return

    message_id = str(uuid.uuid4())
    assistant_message = build_assistant_message(answer, registry, message_id=uuid.UUID(message_id))

    try:
        async for event in stream_grounded_answer(answer, registry, message_id=message_id):
            yield event
    finally:
        await append_grounded_turn(
            client,
            thread_id=thread_id,
            user_message=user_message,
            assistant_message=assistant_message,
            thread_title=thread_title,
        )''', encoding='utf-8')

# 9. Write app/chat/orchestrator.py
Path('backend/app/chat/orchestrator.py').write_text('''\"\"\"Coordinates one chat turn: status updates -> parallel retrieval -> model agent -> validate -> self-correct -> stream & persist.\"\"\"

from __future__ import annotations

import asyncio
import uuid
from collections.abc import AsyncIterator
from supabase import AsyncClient

from app.assistant.agent import run_document_agent
from app.assistant.deps import DocumentAgentDeps, TurnRegistry
from app.assistant.outputs import GroundedAnswer
from app.auth.dependencies import CurrentUser
from app.chat.messages import text_from_parts
from app.chat.streaming import (
    stream_grounded_turn_and_persist,
    stream_error,
    stream_status,
)
from app.grounding.validator import GroundingValidator, prune_unreferenced_citations
from app.retrieval.retriever import DocumentRetriever
from app.schemas.chat import UIMessage

MAX_VALIDATION_ATTEMPTS = 2


async def _yield_status_updates(
    status_queue: asyncio.Queue[tuple[str, str]],
    agent_task: asyncio.Task[GroundedAnswer],
) -> AsyncIterator[str]:
    while not agent_task.done():
        try:
            stage, message = await asyncio.wait_for(status_queue.get(), timeout=0.3)
        except TimeoutError:
            continue
        async for event in stream_status(stage, message):
            yield event

    while not status_queue.empty():
        stage, message = status_queue.get_nowait()
        async for event in stream_status(stage, message):
            yield event


async def run_turn(
    *,
    client: AsyncClient,
    thread_id: uuid.UUID,
    user: CurrentUser,
    user_message: UIMessage,
    thread_title: str,
) -> AsyncIterator[str]:
    loop = asyncio.get_running_loop()
    query = text_from_parts(user_message.parts).strip()
    if not query:
        async for event in stream_error(\"User message is empty.\"):
            yield event
        return

    async for event in stream_status(\"analyzing\", \"Analyzing your question…\"):
        yield event

    retriever = DocumentRetriever()
    grounded: GroundedAnswer | None = None
    validation = None

    for attempt in range(1, MAX_VALIDATION_ATTEMPTS + 1):
        registry = TurnRegistry()
        status_queue = asyncio.Queue()

        def on_status(stage: str, message: str) -> None:
            loop.call_soon_threadsafe(status_queue.put_nowait, (stage, message))

        deps = DocumentAgentDeps(
            retriever=retriever,
            registry=registry,
            thread_id=thread_id,
            user_id=user.id,
            on_status=on_status,
        )
        agent_task = asyncio.create_task(
            asyncio.to_thread(run_document_agent, query, deps)
        )

        async for event in _yield_status_updates(status_queue, agent_task):
            yield event

        try:
            grounded = await agent_task
        except Exception as exc:
            async for event in stream_error(f\"Assistant run failed: {exc}\"):
                yield event
            return

        async for event in stream_status(\"verifying\", \"Verifying citations…\"):
            yield event

        grounded = prune_unreferenced_citations(grounded)
        validation = await GroundingValidator().validate(grounded, registry)
        if validation.ok or attempt == MAX_VALIDATION_ATTEMPTS:
            break

        async for event in stream_status(
            \"retrying\",
            \"Could not fully verify citations; retrying with stricter grounding…\",
        ):
            yield event

    if grounded is None or validation is None:
        async for event in stream_error(\"Assistant run failed before producing an answer.\"):
            yield event
        return

    if validation.ok:
        async for event in stream_status(\"streaming\", \"Preparing answer…\"):
            yield event

    async for event in stream_grounded_turn_and_persist(
        client=client,
        thread_id=thread_id,
        user_message=user_message,
        thread_title=thread_title,
        answer=grounded,
        registry=registry,
        validation=validation,
    ):
        yield event
''', encoding='utf-8')

print('All Phase 6 Python scripts created successfully! Immunity against bash CRLF has been maintained.')
"