# Execute from your repository root
cat << 'EOF' > setup_backend_chat_shell.sh
#!/bin/bash
set -e

# Create directories
mkdir -p backend/app/schemas
mkdir -p backend/app/chat
mkdir -p backend/app/api

# 1. Create schemas/chat.py
cat << 'INNER_EOF' > backend/app/schemas/chat.py
"""Pydantic models for chat API request and response bodies."""

from __future__ import annotations

import uuid
from datetime import date, datetime
from typing import Annotated, Any, Literal

from pydantic import BaseModel, ConfigDict, Field


class TextPart(BaseModel):
    type: Literal["text"] = "text"
    text: str


class CitationPayload(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    citation_index: int = Field(alias="citationIndex")
    chunk_id: uuid.UUID = Field(alias="chunkId")
    excerpt: str
    ticker: str
    company_name: str | None = Field(default=None, alias="companyName")
    form: str
    filing_date: date = Field(alias="filingDate")
    page: str | None = None
    section: str | None = None


class CitationPart(BaseModel):
    type: Literal["data-citation"] = "data-citation"
    id: str | None = None
    data: CitationPayload


class CitationContextChunk(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    chunk_id: uuid.UUID = Field(alias="chunkId")
    chunk_index: int = Field(alias="chunkIndex")
    role: Literal["previous", "anchor", "next"]
    text: str
    page: str | None = None
    section: str | None = None


class CitationContextTable(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    table_index: int = Field(alias="tableIndex")
    title: str | None = None
    units: str | None = None
    markdown: str
    table_data: dict[str, Any] = Field(alias="tableData")


class CitationContextResponse(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    anchor_chunk_id: uuid.UUID = Field(alias="anchorChunkId")
    document_id: uuid.UUID = Field(alias="documentId")
    ticker: str
    company_name: str | None = Field(default=None, alias="companyName")
    form: str
    filing_date: date = Field(alias="filingDate")
    source_url: str = Field(alias="sourceUrl")
    chunks: list[CitationContextChunk]
    table: CitationContextTable | None = None


class StatusPayload(BaseModel):
    stage: str
    message: str


class StatusPart(BaseModel):
    type: Literal["data-status"] = "data-status"
    data: StatusPayload


MessagePart = Annotated[TextPart | CitationPart, Field(discriminator="type")]


class UIMessage(BaseModel):
    id: str | None = None
    role: Literal["user", "assistant", "system"]
    parts: list[MessagePart]


class CreateThreadRequest(BaseModel):
    title: str | None = None


class ThreadResponse(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    id: uuid.UUID
    title: str
    created_at: datetime = Field(serialization_alias="createdAt")
    updated_at: datetime = Field(serialization_alias="updatedAt")


class ThreadListResponse(BaseModel):
    threads: list[ThreadResponse]


class MessageHistoryResponse(BaseModel):
    messages: list[UIMessage]


class StreamRequest(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    thread_id: uuid.UUID = Field(validation_alias="threadId")
    messages: list[UIMessage]


def thread_row_to_response(row: dict[str, Any]) -> ThreadResponse:
    return ThreadResponse(
        id=uuid.UUID(str(row["id"])),
        title=row["title"],
        created_at=row["created_at"],
        updated_at=row["updated_at"],
    )
INNER_EOF

# 2. Create database/chats.py
cat << 'INNER_EOF' > backend/app/database/chats.py
"""Chat thread and message persistence via Supabase."""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any

from fastapi import HTTPException, status
from supabase import AsyncClient

from app.auth.dependencies import CurrentUser
from app.chat.messages import (
    DEFAULT_THREAD_TITLE,
    row_to_ui_message,
    title_from_user_message,
    ui_message_to_insert,
)
from app.database.supabase import get_service_role_client
from app.schemas.chat import CitationPart, CitationPayload, ThreadResponse, UIMessage, thread_row_to_response


@dataclass(frozen=True, slots=True)
class ThreadRow:
    id: uuid.UUID
    user_id: uuid.UUID
    title: str


async def require_thread_access(thread_id: uuid.UUID, user: CurrentUser) -> ThreadRow:
    client = await get_service_role_client()
    response = await (
        client.table("chat_threads")
        .select("id,user_id,title")
        .eq("id", str(thread_id))
        .maybe_single()
        .execute()
    )

    if response.data is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Thread not found",
        )

    row = response.data
    owner_id = uuid.UUID(str(row["user_id"]))
    if owner_id != user.id:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Forbidden",
        )

    return ThreadRow(
        id=uuid.UUID(str(row["id"])),
        user_id=owner_id,
        title=row["title"],
    )


async def list_threads(client: AsyncClient, user: CurrentUser) -> list[ThreadResponse]:
    response = await (
        client.table("chat_threads")
        .select("id,title,created_at,updated_at")
        .eq("user_id", str(user.id))
        .order("updated_at", desc=True)
        .execute()
    )
    return [thread_row_to_response(row) for row in response.data]


async def create_thread(
    client: AsyncClient,
    user: CurrentUser,
    *,
    title: str | None = None,
) -> ThreadResponse:
    thread_id = uuid.uuid4()
    response = await (
        client.table("chat_threads")
        .insert(
            {
                "id": str(thread_id),
                "user_id": str(user.id),
                "title": title or DEFAULT_THREAD_TITLE,
            }
        )
        .select("id,title,created_at,updated_at")
        .execute()
    )
    return thread_row_to_response(response.data[0])


async def delete_thread(client: AsyncClient, thread_id: uuid.UUID) -> None:
    await client.table("chat_threads").delete().eq("id", str(thread_id)).execute()


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
                "id": str(uuid.uuid4()),
                "message_id": message_id,
                "chunk_id": str(data.chunk_id),
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


async def load_messages(client: AsyncClient, thread_id: uuid.UUID) -> list[UIMessage]:
    response = await (
        client.table("chat_messages")
        .select("id,role,content,parts,sequence")
        .eq("thread_id", str(thread_id))
        .order("sequence")
        .execute()
    )
    messages = [row_to_ui_message(row) for row in response.data]
    assistant_ids = [message.id for message in messages if message.role == "assistant" and message.id]
    if not assistant_ids:
        return messages

    citations_response = await (
        client.table("message_citations")
        .select(
            "message_id,citation_index,excerpt,chunk_id,ticker,company_name,form,filing_date,page,section"
        )
        .in_("message_id", assistant_ids)
        .order("citation_index")
        .execute()
    )
    citations_by_message: dict[str, list[dict[str, Any]]] = {}
    for row in citations_response.data:
        message_id = str(row["message_id"])
        citations_by_message.setdefault(message_id, []).append(row)

    hydrated: list[UIMessage] = []
    for message in messages:
        if message.role != "assistant" or message.id is None:
            hydrated.append(message)
            continue

        citation_rows = citations_by_message.get(message.id, [])
        if not citation_rows:
            hydrated.append(message)
            continue

        existing_citation_ids = {
            part.data.chunk_id
            for part in message.parts
            if isinstance(part, CitationPart)
        }
        parts = list(message.parts)
        for row in citation_rows:
            chunk_id = uuid.UUID(str(row["chunk_id"]))
            if chunk_id in existing_citation_ids:
                continue
            parts.append(
                CitationPart(
                    id=str(chunk_id),
                    data=CitationPayload(
                        citation_index=int(row["citation_index"]),
                        chunk_id=chunk_id,
                        excerpt=row["excerpt"],
                        ticker=row["ticker"],
                        company_name=row.get("company_name"),
                        form=row["form"],
                        filing_date=row["filing_date"],
                        page=row.get("page"),
                        section=row.get("section"),
                    ),
                )
            )
        hydrated.append(UIMessage(id=message.id, role=message.role, parts=parts))

    return hydrated


async def get_next_sequence(client: AsyncClient, thread_id: uuid.UUID) -> int:
    response = await (
        client.table("chat_messages")
        .select("sequence")
        .eq("thread_id", str(thread_id))
        .order("sequence", desc=True)
        .limit(1)
        .execute()
    )
    if not response.data:
        return 0
    return int(response.data[0]["sequence"]) + 1


async def append_grounded_turn(
    client: AsyncClient,
    *,
    thread_id: uuid.UUID,
    user_message: UIMessage,
    assistant_message: UIMessage,
    thread_title: str,
) -> None:
    next_sequence = await get_next_sequence(client, thread_id)
    rows = [
        ui_message_to_insert(
            user_message,
            thread_id=thread_id,
            sequence=next_sequence,
        ),
        ui_message_to_insert(
            assistant_message,
            thread_id=thread_id,
            sequence=next_sequence + 1,
            message_id=uuid.UUID(assistant_message.id) if assistant_message.id else None,
        ),
    ]
    await client.table("chat_messages").insert(rows).execute()

    citation_rows = _citation_rows_from_message(assistant_message)
    if citation_rows:
        await client.table("message_citations").insert(citation_rows).execute()

    updates: dict[str, Any] = {"updated_at": datetime.now(UTC).isoformat()}
    if thread_title == DEFAULT_THREAD_TITLE:
        updates["title"] = title_from_user_message(user_message)

    await (
        client.table("chat_threads")
        .update(updates)
        .eq("id", str(thread_id))
        .execute()
    )
INNER_EOF

# 3. Create chat/messages.py
cat << 'INNER_EOF' > backend/app/chat/messages.py
"""Convert between AI SDK UI messages and chat_messages rows."""

from __future__ import annotations

import uuid
from typing import Any

from fastapi import HTTPException, status

from app.schemas.chat import (
    CitationPart,
    CitationPayload,
    MessagePart,
    TextPart,
    UIMessage,
)

DEFAULT_THREAD_TITLE = "New chat"
MAX_TITLE_LENGTH = 255


def text_from_parts(parts: list[MessagePart]) -> str:
    return "".join(part.text for part in parts if isinstance(part, TextPart))


def extract_last_user_message(messages: list[UIMessage]) -> UIMessage:
    for message in reversed(messages):
        if message.role == "user":
            return message
    raise HTTPException(
        status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
        detail="Request must include at least one user message",
    )


def ui_message_to_insert(
    message: UIMessage,
    *,
    thread_id: uuid.UUID,
    sequence: int,
    message_id: uuid.UUID | None = None,
) -> dict[str, Any]:
    parts = [part.model_dump(by_alias=True, mode="json") for part in message.parts]
    return {
        "id": str(message_id or uuid.uuid4()),
        "thread_id": str(thread_id),
        "role": message.role,
        "content": text_from_parts(message.parts) or None,
        "parts": parts,
        "sequence": sequence,
    }


def _parse_part(raw: dict[str, Any]) -> MessagePart:
    part_type = raw.get("type")
    if part_type == "text":
        return TextPart.model_validate(raw)
    if part_type == "data-citation":
        return CitationPart.model_validate(raw)
    raise ValueError(f"Unsupported message part type: {part_type!r}")


def row_to_ui_message(row: dict[str, Any]) -> UIMessage:
    raw_parts = row.get("parts") or []
    parts: list[MessagePart] = []
    for part in raw_parts:
        parts.append(_parse_part(part))
    if not parts and row.get("content"):
        parts = [TextPart(text=row["content"])]

    return UIMessage(
        id=str(row["id"]),
        role=row["role"],
        parts=parts,
    )


def title_from_user_message(message: UIMessage) -> str:
    text = text_from_parts(message.parts).strip()
    if not text:
        return DEFAULT_THREAD_TITLE
    if len(text) <= MAX_TITLE_LENGTH:
        return text
    return text[: MAX_TITLE_LENGTH - 3] + "..."
INNER_EOF

# 4. Create chat/streaming.py (stubbed for Phase 3)
cat << 'INNER_EOF' > backend/app/chat/streaming.py
"""AI SDK-compatible SSE streaming for stubbed grounded assistant replies."""

from __future__ import annotations

import json
import uuid
import asyncio
from collections.abc import AsyncIterator

from app.schemas.chat import UIMessage, TextPart


def sse_event(payload: dict[str, object]) -> str:
    return f"data: {json.dumps(payload, separators=(',', ':'), default=str)}\n\n"


async def stream_status(stage: str, message: str) -> AsyncIterator[str]:
    yield sse_event({
        "type": "data-status",
        "data": {
            "stage": stage,
            "message": message
        }
    })


async def stream_stubbed_answer(query: str, message_id: str) -> AsyncIterator[str]:
    yield sse_event({"type": "start", "messageId": message_id})
    yield sse_event({"type": "text-start", "id": message_id})

    reply_content = (
        f"Hello! I am your Document Copilot research assistant. "
        f"You asked: '{query}'. "
        f"In later implementation phases, this space will contain a fully grounded answer "
        f"generated by our PydanticAI model, complete with inline interactive citations "
        f"mapping directly to indexed SEC filing database chunks. Everything is working correctly."
    )

    for word in reply_content.split(" "):
        yield sse_event({
            "type": "text-delta",
            "id": message_id,
            "delta": f"{word} "
        })
        await asyncio.sleep(0.06)

    yield sse_event({"type": "text-end", "id": message_id})
    yield sse_event({"type": "finish"})
INNER_EOF

# 5. Create chat/orchestrator.py (stubbed for Phase 3)
cat << 'INNER_EOF' > backend/app/chat/orchestrator.py
"""Coordinates one chat turn Turn: status updates -> mock generation -> persist."""

from __future__ import annotations

import uuid
import asyncio
from collections.abc import AsyncIterator

from supabase import AsyncClient

from app.auth.dependencies import CurrentUser
from app.chat.messages import text_from_parts
from app.chat.streaming import (
    stream_stubbed_answer,
    stream_status,
    sse_event,
)
from app.database.chats import append_grounded_turn
from app.schemas.chat import UIMessage, TextPart


async def run_turn(
    *,
    client: AsyncClient,
    thread_id: uuid.UUID,
    user: CurrentUser,
    user_message: UIMessage,
    thread_title: str,
) -> AsyncIterator[str]:
    query = text_from_parts(user_message.parts).strip()
    if not query:
        yield sse_event({"type": "error", "errorText": "User message is empty."})
        return

    # 1. Yield simulated search steps
    async for event in stream_status("searching", "Searching SEC filings..."):
        yield event
    await asyncio.sleep(0.6)

    async for event in stream_status("reading", "Reading source passages..."):
        yield event
    await asyncio.sleep(0.4)

    async for event in stream_status("verifying", "Verifying citations..."):
        yield event
    await asyncio.sleep(0.4)

    # 2. Yield text deltas
    message_id = str(uuid.uuid4())
    async for event in stream_stubbed_answer(query, message_id):
        yield event

    # 3. Assemble and save turning record in background
    reply_content = (
        f"Hello! I am your Document Copilot research assistant. "
        f"You asked: '{query}'. "
        f"In later implementation phases, this space will contain a fully grounded answer "
        f"generated by our PydanticAI model, complete with inline interactive citations "
        f"mapping directly to indexed SEC filing database chunks. Everything is working correctly."
    )
    
    assistant_message = UIMessage(
        id=message_id,
        role="assistant",
        parts=[TextPart(text=reply_content)]
    )

    await append_grounded_turn(
        client=client,
        thread_id=thread_id,
        user_message=user_message,
        assistant_message=assistant_message,
        thread_title=thread_title
    )
INNER_EOF

# 6. Create app/api/auth.py
cat << 'INNER_EOF' > backend/app/api/auth.py
"""FastAPI routes for user profile verification."""

from __future__ import annotations

from fastapi import APIRouter, Depends

from app.auth.dependencies import CurrentUser, get_current_user

router = APIRouter(tags=["auth"])


@router.get("/me")
async def me(user: CurrentUser = Depends(get_current_user)) -> dict[str, str]:
    return {"id": str(user.id), "email": user.email}
INNER_EOF

# 7. Create app/api/chat.py
cat << 'INNER_EOF' > backend/app/api/chat.py
"""FastAPI routes for chat threads and streaming."""

from __future__ import annotations

import uuid

from fastapi import APIRouter, Depends, Query, status
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
from app.schemas.chat import (
    CreateThreadRequest,
    MessageHistoryResponse,
    StreamRequest,
    ThreadListResponse,
    ThreadResponse,
)

router = APIRouter(prefix="/chat", tags=["chat"])


@router.get("/threads")
async def get_threads(
    user: CurrentUser = Depends(get_current_user),
    access_token: str = Depends(get_access_token),
) -> ThreadListResponse:
    client = await create_user_client(access_token)
    threads = await list_threads(client, user)
    return ThreadListResponse(threads=threads)


@router.post("/threads")
async def post_thread(
    body: CreateThreadRequest,
    user: CurrentUser = Depends(get_current_user),
    access_token: str = Depends(get_access_token),
) -> ThreadResponse:
    client = await create_user_client(access_token)
    return await create_thread(client, user, title=body.title)


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

    return StreamingResponse(
        run_turn(
            client=client,
            thread_id=body.thread_id,
            user=user,
            user_message=user_message,
            thread_title=thread.title,
        ),
        media_type="text/event-stream",
    )
INNER_EOF

# 8. Update app/main.py
cat << 'INNER_EOF' > backend/app/main.py
"""FastAPI application entrypoint."""

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.api.auth import router as auth_router
from app.api.chat import router as chat_router
from app.config import settings

app = FastAPI(title="Document Copilot")

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.allowed_origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
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

echo "Backend Chat Shell setup complete! Run cleanup."
rm setup_backend_chat_shell.sh
EOF

# Run the automation script to write all backend files
bash setup_backend_chat_shell.sh