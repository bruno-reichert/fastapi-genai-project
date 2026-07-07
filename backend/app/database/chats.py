"""Chat thread and message persistence via direct, high-performance SQL."""

from __future__ import annotations

import uuid
import asyncio
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any

from fastapi import HTTPException, status
from sqlalchemy import select, delete
from sqlalchemy.orm import joinedload
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
from app.schemas.chat import CitationPart, CitationPayload, ThreadResponse, UIMessage


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
    print("[DB] Inside create_thread database transaction...", flush=True)
    thread_id = uuid.uuid4()
    
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

    res = await asyncio.to_thread(_sync_create)
    print(f"[DB] Direct SQL create_thread successfully committed! ID: {thread_id}", flush=True)
    return res


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

    await asyncio.to_thread(_sync_append)