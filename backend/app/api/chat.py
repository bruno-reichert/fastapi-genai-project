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
