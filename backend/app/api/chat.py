"""FastAPI routes for chat threads and streaming with diagnostic logs and stream interceptors."""

from __future__ import annotations

import uuid
import traceback
import json
from collections.abc import AsyncIterator

from fastapi import APIRouter, Body, Depends, Query, Request, status, HTTPException
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


def sse_event(payload: dict[str, object]) -> str:
    return f"data: {json.dumps(payload, separators=(',', ':'), default=str)}\n\n"


async def safe_stream_wrapper(generator: AsyncIterator[str]) -> AsyncIterator[str]:
    """Intercept any exceptions raised during active streaming and print the traceback."""
    try:
        async for event in generator:
            yield event
    except Exception as exc:
        print("\n" + "="*50)
        print(f"[STREAM EXCEPTION] An unhandled error occurred during active streaming: {exc}", flush=True)
        traceback.print_exc()
        print("="*50 + "\n")
        
        # Safely yield an error event to the browser before closing the socket
        yield sse_event({"type": "error", "errorText": f"Streaming error: {exc}"})


@router.get("/threads")
async def get_threads(
    user: CurrentUser = Depends(get_current_user),
    access_token: str = Depends(get_access_token),
) -> ThreadListResponse:
    print("[ROUTE] Entered GET /chat/threads", flush=True)
    try:
        await ensure_user(user)
    except Exception as exc:
        print(f"[ROUTE] EXCEPTION occurred inside GET threads -> ensure_user: {exc}", flush=True)
        traceback.print_exc()
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
    print("[ROUTE] Entered POST /chat/threads with raw Request object", flush=True)
    print(f"[ROUTE] User context resolved: {user.email} (id: {user.id})", flush=True)
    
    try:
        body_json = await request.json()
        print(f"[ROUTE] DIRECT PAYLOAD LOG -> Received JSON: {body_json}", flush=True)
        payload = CreateThreadRequest.model_validate(body_json)
        print(f"[ROUTE] Pydantic validation successful: {payload}", flush=True)
    except Exception as exc:
        print(f"[ROUTE] EXCEPTION occurred during manual JSON body parsing: {exc}", flush=True)
        traceback.print_exc()
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="Could not parse or validate request payload."
        )
    
    try:
        print("[ROUTE] Provisioning user profile via ensure_user...", flush=True)
        await ensure_user(user)
        print("[ROUTE] user profile successfully verified/provisioned!", flush=True)
    except Exception as exc:
        print(f"[ROUTE] EXCEPTION occurred inside POST thread -> ensure_user: {exc}", flush=True)
        traceback.print_exc()
        raise exc
    
    print("[ROUTE] Initializing user-scoped database client...", flush=True)
    client = await create_user_client(access_token)
    
    title = payload.title if payload else None
    print(f"[ROUTE] Inserting thread row with title: {title!r}...", flush=True)
    try:
        res = await create_thread(client, user, title=title)
        print("[ROUTE] Thread row successfully committed! Returning response.", flush=True)
        return res
    except Exception as exc:
        print(f"[ROUTE] EXCEPTION occurred inside POST thread -> create_thread: {exc}", flush=True)
        traceback.print_exc()
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

    # Wrap the generator inside the safe exception interceptor before streaming
    generator = run_turn(
        client=client,
        thread_id=body.thread_id,
        user=user,
        user_message=user_message,
        thread_title=thread.title,
    )
    
    return StreamingResponse(
        safe_stream_wrapper(generator),
        media_type="text/event-stream",
    )