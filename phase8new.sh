# Execute from your repository root
cat << 'EOF' > setup_backend_logging.sh
#!/bin/bash
set -e

# Create directories
mkdir -p backend/app/assistant
mkdir -p backend/app/grounding

# 1. Update app/main.py (Configure structlog)
cat << 'INNER_EOF' > backend/app/main.py
"""FastAPI application entrypoint with structured logging and global error handling."""

from __future__ import annotations

import logging
import sys
import structlog
from fastapi import FastAPI
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from app.api.auth import router as auth_router
from app.api.chat import router as chat_router
from app.config import settings

# Initialize standard Python logging to match structlog
logging.basicConfig(
    format="%(message)s",
    stream=sys.stdout,
    level=logging.INFO,
)

# Configure structlog to output clean, structured JSON in terminal
structlog.configure(
    processors=[
        structlog.contextvars.merge_contextvars,
        structlog.processors.add_log_level,
        structlog.processors.TimeStamper(fmt="iso"),
        structlog.processors.JSONRenderer(),
    ],
    wrapper_class=structlog.make_filtering_bound_logger(logging.INFO),
    context_class=dict,
    logger_factory=structlog.PrintLoggerFactory(),
    cache_logger_on_first_use=True,
)

logger = structlog.get_logger()

app = FastAPI(title="Document Copilot")

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.allowed_origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.exception_handler(RequestValidationError)
async def validation_exception_handler(request, exc: RequestValidationError):
    """Intercept validation anomalies and log metrics inside a structured JSON schema."""
    raw_body = None
    try:
        body_bytes = await request.body()
        raw_body = body_bytes.decode("utf-8")
    except Exception:
        raw_body = "<failed to decode body>"

    logger.error(
        "request_validation_failed",
        url=str(request.url),
        method=request.method,
        errors=exc.errors(),
        body=raw_body,
    )
    
    # Sanitize bytes inside error dicts to ensure JSON serializable
    sanitized_errors = []
    for error in exc.errors():
        sanitized_error = dict(error)
        if "input" in sanitized_error and isinstance(sanitized_error["input"], bytes):
            try:
                sanitized_error["input"] = sanitized_error["input"].decode("utf-8")
            except Exception:
                sanitized_error["input"] = str(sanitized_error["input"])
        sanitized_errors.append(sanitized_error)
    
    return JSONResponse(
        status_code=422,
        content={"detail": sanitized_errors},
    )


app.include_router(auth_router)
app.include_router(chat_router)


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}


if __name__ == "__main__":
    import uvicorn

    uvicorn.run("app.main:app", host="0.0.0.0", port=8000, reload=True)
INNER_EOF

# 2. Update app/api/chat.py (Structured logging in routes)
cat << 'INNER_EOF' > backend/app/api/chat.py
"""FastAPI routes for chat threads and streaming with structured diagnostics."""

from __future__ import annotations

import uuid
import json
import structlog
from collections.abc import AsyncIterator

from fastapi import APIRouter, Depends, Query, Request, status, HTTPException
from fastapi.responses import StreamingResponse

from app.auth.dependencies import CurrentUser, get_access_token, get_current_user
from app.chat.messages import extract_last_user_message
from app.chat.orchestrator import run_turn
from app.database.chats import (
    create_thread,
    delete_thread,
    list_threads,
    load_messages,
    require_thread_access,
)
from app.database.supabase import create_user_client
from app.database.users import ensure_user
from app.schemas.chat import (
    CreateThreadRequest,
    MessageHistoryResponse,
    StreamRequest,
    ThreadListResponse,
    ThreadResponse,
)

router = APIRouter(prefix="/chat", tags=["chat"])
logger = structlog.get_logger()


def sse_event(payload: dict[str, object]) -> str:
    return f"data: {json.dumps(payload, separators=(',', ':'), default=str)}\n\n"


async def safe_stream_wrapper(generator: AsyncIterator[str], thread_id: uuid.UUID) -> AsyncIterator[str]:
    """Intercept any exceptions raised during active streaming and log natively."""
    try:
        async for event in generator:
            yield event
    except Exception as exc:
        logger.exception(
            "unhandled_stream_exception",
            thread_id=str(thread_id),
            error=str(exc),
        )
        yield sse_event({"type": "error", "errorText": f"Streaming error: {exc}"})


@router.get("/threads")
async def get_threads(
    user: CurrentUser = Depends(get_current_user),
    access_token: str = Depends(get_access_token),
) -> ThreadListResponse:
    logger.info("get_threads_triggered", user_id=str(user.id), email=user.email)
    try:
        await ensure_user(user)
    except Exception as exc:
        logger.exception("get_threads_provision_failed", user_id=str(user.id), error=str(exc))
        raise exc

    client = await create_user_client(access_token)
    threads = await list_threads(client, user)
    return ThreadListResponse(threads=threads)


@router.post("/threads")
async def post_thread(
    request: Request,
    user: CurrentUser = Depends(get_current_user),
    access_token: str = Depends(get_access_token),
) -> ThreadResponse:
    logger.info("post_thread_triggered", user_id=str(user.id), email=user.email)
    
    try:
        body_json = await request.json()
        payload = CreateThreadRequest.model_validate(body_json)
    except Exception as exc:
        logger.error("post_thread_parsing_failed", user_id=str(user.id), error=str(exc))
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="Could not parse or validate request payload."
        )
    
    try:
        await ensure_user(user)
    except Exception as exc:
        logger.exception("post_thread_provision_failed", user_id=str(user.id), error=str(exc))
        raise exc
    
    client = await create_user_client(access_token)
    title = payload.title if payload else None
    
    logger.info("post_thread_db_insert", user_id=str(user.id), title=title)
    try:
        res = await create_thread(client, user, title=title)
        logger.info("post_thread_success", user_id=str(user.id), thread_id=str(res.id))
        return res
    except Exception as exc:
        logger.exception("post_thread_insert_failed", user_id=str(user.id), error=str(exc))
        raise exc


@router.get("/threads/{thread_id}/messages")
async def get_thread_messages(
    thread_id: uuid.UUID,
    user: CurrentUser = Depends(get_current_user),
    access_token: str = Depends(get_access_token),
) -> MessageHistoryResponse:
    await require_thread_access(thread_id, user)
    client = await create_user_client(access_token)
    messages = await load_messages(client, thread_id)
    return MessageHistoryResponse(messages=messages)


@router.delete("/threads/{thread_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_thread_route(
    thread_id: uuid.UUID,
    user: CurrentUser = Depends(get_current_user),
    access_token: str = Depends(get_access_token),
) -> None:
    await require_thread_access(thread_id, user)
    client = await create_user_client(access_token)
    await delete_thread(client, thread_id)


@router.post("/stream")
async def post_stream(
    body: StreamRequest,
    user: CurrentUser = Depends(get_current_user),
    access_token: str = Depends(get_access_token),
) -> StreamingResponse:
    thread = await require_thread_access(body.thread_id, user)
    user_message = extract_last_user_message(body.messages)
    client = await create_user_client(access_token)

    generator = run_turn(
        client=client,
        thread_id=body.thread_id,
        user=user,
        user_message=user_message,
        thread_title=thread.title,
    )
    
    return StreamingResponse(
        safe_stream_wrapper(generator, body.thread_id),
        media_type="text/event-stream",
    )
INNER_EOF

# 3. Update app/chat/orchestrator.py (Structured logging in generator transitions)
cat << 'INNER_EOF' > backend/app/chat/orchestrator.py
"""Coordinates one chat turn: status updates -> parallel retrieval -> model agent -> validate -> self-correct -> stream & persist."""

from __future__ import annotations

import asyncio
import uuid
import structlog
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
logger = structlog.get_logger()


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
    
    logger.info(
        "run_turn_initiated",
        thread_id=str(thread_id),
        user_id=str(user.id),
        query_length=len(query),
    )

    if not query:
        logger.error("run_turn_empty_query", thread_id=str(thread_id))
        async for event in stream_error("User message is empty."):
            yield event
        return

    async for event in stream_status("analyzing", "Analyzing your question…"):
        yield event

    retriever = DocumentRetriever()
    grounded: GroundedAnswer | None = None
    validation = None

    for attempt in range(1, MAX_VALIDATION_ATTEMPTS + 1):
        logger.info("generation_attempt_started", thread_id=str(thread_id), attempt=attempt)
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
            run_document_agent(query, deps)
        )

        async for event in _yield_status_updates(status_queue, agent_task):
            yield event

        try:
            grounded = await agent_task
            logger.info("generation_attempt_success", thread_id=str(thread_id), attempt=attempt)
        except Exception as exc:
            logger.exception(
                "generation_attempt_failed",
                thread_id=str(thread_id),
                attempt=attempt,
                error=str(exc),
            )
            async for event in stream_error(f"Assistant run failed: {exc}"):
                yield event
            return

        async for event in stream_status("verifying", "Verifying citations…"):
            yield event

        grounded = prune_unreferenced_citations(grounded)
        validation = await GroundingValidator().validate(grounded, registry)
        
        logger.info(
            "grounding_validation_evaluated",
            thread_id=str(thread_id),
            attempt=attempt,
            ok=validation.ok,
            error=validation.error,
        )
        
        if validation.ok or attempt == MAX_VALIDATION_ATTEMPTS:
            break

        logger.warn("grounding_validation_failed_triggering_retry", thread_id=str(thread_id), attempt=attempt)
        async for event in stream_status(
            "retrying",
            "Could not fully verify citations; retrying with stricter grounding…",
        ):
            yield event

    if grounded is None or validation is None:
        async for event in stream_error("Assistant run failed before producing an answer."):
            yield event
        return

    if validation.ok:
        async for event in stream_status("streaming", "Preparing answer…"):
            yield event

    logger.info("commencing_stream_output_and_save", thread_id=str(thread_id))
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
    logger.info("run_turn_completed", thread_id=str(thread_id))
INNER_EOF

# 4. Update app/database/chats.py (Structured logging in database operations)
cat << 'INNER_EOF' > backend/app/database/chats.py
"""Chat thread and persistence via direct SQL with structured diagnostics."""

from __future__ import annotations

import uuid
import asyncio
import structlog
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any

from fastapi import HTTPException, status
from sqlalchemy import select, delete
from supabase import AsyncClient

from app.auth.dependencies import CurrentUser
from app.chat.messages import (
    DEFAULT_THREAD_TITLE,
    title_from_user_message,
)
from app.database.session import get_session
from app.database.models.chat_threads import ChatThread
from app.database.models.chat_messages import ChatMessage, MessageRole
from app.database.models.message_citations import MessageCitation
from app.database.models.user import User
from app.schemas.chat import CitationPart, CitationPayload, TextPart, ThreadResponse, UIMessage

logger = structlog.get_logger()


@dataclass(frozen=True, slots=True)
class ThreadRow:
    id: uuid.UUID
    user_id: uuid.UUID
    title: str


async def require_thread_access(thread_id: uuid.UUID, user: CurrentUser) -> ThreadRow:
    """Validate that the requesting user owns the targeted chat thread."""
    def _sync_check() -> ThreadRow:
        with get_session() as session:
            thread = session.scalar(
                select(ChatThread)
                .where(ChatThread.id == thread_id)
            )
            if thread is None:
                raise HTTPException(
                    status_code=status.HTTP_404_NOT_FOUND,
                    detail="Thread not found",
                )
            if thread.user_id != user.id:
                raise HTTPException(
                    status_code=status.HTTP_403_FORBIDDEN,
                    detail="Forbidden",
                )
            return ThreadRow(id=thread.id, user_id=thread.user_id, title=thread.title or "")

    return await asyncio.to_thread(_sync_check)


async def list_threads(client: AsyncClient, user: CurrentUser) -> list[ThreadResponse]:
    """Retrieve all chat threads associated with the authenticated user."""
    def _sync_list() -> list[ThreadResponse]:
        with get_session() as session:
            threads = session.scalars(
                select(ChatThread)
                .where(ChatThread.user_id == user.id)
                .order_by(ChatThread.updated_at.desc())
            ).all()
            return [
                ThreadResponse(
                    id=t.id,
                    title=t.title or "New chat",
                    created_at=t.created_at,
                    updated_at=t.updated_at,
                )
                for t in threads
            ]

    return await asyncio.to_thread(_sync_list)


async def create_thread(
    client: AsyncClient,
    user: CurrentUser,
    *,
    title: str | None = None,
) -> ThreadResponse:
    """Create a new chat thread using secure, direct SQL."""
    thread_id = uuid.uuid4()
    logger.info("db_create_thread_initiated", user_id=str(user.id), thread_id=str(thread_id))
    
    def _sync_create() -> ThreadResponse:
        with get_session() as session:
            new_thread = ChatThread(
                id=thread_id,
                user_id=user.id,
                title=title or DEFAULT_THREAD_TITLE,
            )
            session.add(new_thread)
            session.commit()
            session.refresh(new_thread)
            
            return ThreadResponse(
                id=new_thread.id,
                title=new_thread.title or "New chat",
                created_at=new_thread.created_at,
                updated_at=new_thread.updated_at,
            )

    try:
        res = await asyncio.to_thread(_sync_create)
        logger.info("db_create_thread_success", user_id=str(user.id), thread_id=str(thread_id))
        return res
    except Exception as exc:
        logger.exception("db_create_thread_failed", user_id=str(user.id), error=str(exc))
        raise exc


async def delete_thread(client: AsyncClient, thread_id: uuid.UUID) -> None:
    """Permanently delete a thread and all dependent cascade records."""
    def _sync_delete() -> None:
        with get_session() as session:
            session.execute(
                delete(ChatThread).where(ChatThread.id == thread_id)
            )
            session.commit()

    await asyncio.to_thread(_sync_delete)


def _citation_rows_from_message(
    assistant_message: UIMessage,
) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    message_id = assistant_message.id
    if message_id is None:
        return rows

    for part in assistant_message.parts:
        if not isinstance(part, CitationPart):
            continue
        data: CitationPayload = part.data
        rows.append(
            {
                "id": uuid.uuid4(),
                "message_id": uuid.UUID(message_id),
                "chunk_id": data.chunk_id,
                "citation_index": data.citation_index,
                "excerpt": data.excerpt,
                "ticker": data.ticker,
                "company_name": data.company_name,
                "form": data.form,
                "filing_date": data.filing_date.isoformat(),
                "page": data.page,
                "section": data.section,
            }
        )
    return rows


def _row_to_ui_message(message: ChatMessage, citations: list[MessageCitation]) -> UIMessage:
    raw_parts = message.message_json.get("parts") if message.message_json else []
    parts: list[Any] = []
    if raw_parts:
        for part in raw_parts:
            part_type = part.get("type")
            if part_type == "text":
                parts.append(TextPart.model_validate(part))
    else:
        parts.append(TextPart(text=message.content))

    for citation in citations:
        parts.append(
            CitationPart(
                id=str(citation.chunk_id),
                data=CitationPayload(
                    citation_index=citation.citation_index,
                    chunk_id=citation.chunk_id,
                    excerpt=citation.excerpt,
                    ticker=citation.ticker,
                    company_name=citation.company_name,
                    form=citation.form,
                    filing_date=citation.filing_date,
                    page=citation.page,
                    section=citation.section,
                ),
            )
        )

    return UIMessage(
        id=str(message.id),
        role=message.role.value,
        parts=parts,
    )


async def load_messages(client: AsyncClient, thread_id: uuid.UUID) -> list[UIMessage]:
    """Load and hydrate message histories with integrated citations."""
    def _sync_load() -> list[UIMessage]:
        with get_session() as session:
            messages = session.scalars(
                select(ChatMessage)
                .where(ChatMessage.thread_id == thread_id)
                .order_by(ChatMessage.sequence)
            ).all()

            hydrated: list[UIMessage] = []
            for msg in messages:
                citations = []
                if msg.role == MessageRole.ASSISTANT:
                    citations = list(session.scalars(
                        select(MessageCitation)
                        .where(MessageCitation.message_id == msg.id)
                        .order_by(MessageCitation.citation_index)
                    ).all())
                hydrated.append(_row_to_ui_message(msg, citations))
            return hydrated

    return await asyncio.to_thread(_sync_load)


async def get_next_sequence(session: Any, thread_id: uuid.UUID) -> int:
    row = session.execute(
        select(ChatMessage.sequence)
        .where(ChatMessage.thread_id == thread_id)
        .order_by(ChatMessage.sequence.desc())
        .limit(1)
    ).first()
    if not row:
        return 0
    return int(row[0]) + 1


async def append_grounded_turn(
    client: AsyncClient,
    *,
    thread_id: uuid.UUID,
    user_message: UIMessage,
    assistant_message: UIMessage,
    thread_title: str,
) -> None:
    """Save user and assistant messages with integrated citations using direct SQL."""
    logger.info("db_append_turn_initiated", thread_id=str(thread_id))
    
    def _sync_append() -> None:
        with get_session() as session:
            next_sequence = session.execute(
                select(ChatMessage.sequence)
                .where(ChatMessage.thread_id == thread_id)
                .order_by(ChatMessage.sequence.desc())
                .limit(1)
            ).first()
            seq = int(next_sequence[0]) + 1 if next_sequence else 0

            # 1. Insert user message
            user_text = "".join(p.text for p in user_message.parts if isinstance(p, TextPart))
            user_row = ChatMessage(
                id=uuid.uuid4(),
                thread_id=thread_id,
                role=MessageRole.USER,
                sequence=seq,
                content=user_text,
                message_json={
                    "parts": [p.model_dump(by_alias=True, mode="json") for p in user_message.parts]
                }
            )
            session.add(user_row)

            # 2. Insert assistant message
            assistant_text = "".join(p.text for p in assistant_message.parts if isinstance(p, TextPart))
            assistant_row = ChatMessage(
                id=uuid.UUID(assistant_message.id) if assistant_message.id else uuid.uuid4(),
                thread_id=thread_id,
                role=MessageRole.ASSISTANT,
                sequence=seq + 1,
                content=assistant_text,
                message_json={
                    "parts": [p.model_dump(by_alias=True, mode="json") for p in assistant_message.parts if isinstance(p, TextPart)]
                }
            )
            session.add(assistant_row)

            # 3. Insert citations
            citation_rows = _citation_rows_from_message(assistant_message)
            for row in citation_rows:
                session.add(
                    MessageCitation(
                        id=row["id"],
                        message_id=assistant_row.id,
                        chunk_id=row["chunk_id"],
                        citation_index=row["citation_index"],
                        excerpt=row["excerpt"],
                        ticker=row["ticker"],
                        company_name=row["company_name"],
                        form=row["form"],
                        filing_date=datetime.strptime(row["filing_date"], "%Y-%m-%d").date(),
                        page=row["page"],
                        section=row["section"],
                    )
                )

            # 4. Update thread title if needed
            thread = session.scalar(select(ChatThread).where(ChatThread.id == thread_id))
            if thread:
                thread.updated_at = datetime.now(UTC)
                if thread.title == DEFAULT_THREAD_TITLE:
                    thread.title = title_from_user_message(user_message)

            session.commit()

    try:
        await asyncio.to_thread(_sync_append)
        logger.info("db_append_turn_success", thread_id=str(thread_id))
    except Exception as exc:
        logger.exception("db_append_turn_failed", thread_id=str(thread_id), error=str(exc))
        raise exc
INNER_EOF

echo "Backend Structured Logging integration complete! Clean up script."
rm setup_backend_logging.sh
EOF

# Execute the setup script
bash setup_backend_logging.sh