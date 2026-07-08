"""Coordinates one chat turn: parallel retrieval -> model agent -> validate -> self-correct -> stream & persist."""

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
from app.retrieval.types import format_passages_for_agent
from app.schemas.chat import UIMessage

MAX_VALIDATION_ATTEMPTS = 2
logger = structlog.get_logger()


async def run_turn(
    *,
    client: AsyncClient,
    thread_id: uuid.UUID,
    user: CurrentUser,
    user_message: UIMessage,
    thread_title: str,
) -> AsyncIterator[str]:
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

    # 1. Start parallel database pre-retrieval
    async for event in stream_status("searching", "Searching SEC filings…"):
        yield event

    retriever = DocumentRetriever()
    
    # Run the high-performance hybrid search inside Python natively
    logger.info("executing_hybrid_search", thread_id=str(thread_id))
    try:
        # Resolve any active filters dynamically (e.g. scoping AAPL or NVDA)
        ticker_filter = None
        query_lower = query.lower()
        if "apple" in query_lower or "aapl" in query_lower:
            ticker_filter = "AAPL"
        elif "nvidia" in query_lower or "nvda" in query_lower:
            ticker_filter = "NVDA"
        elif "microsoft" in query_lower or "msft" in query_lower:
            ticker_filter = "MSFT"
        elif "amazon" in query_lower or "amzn" in query_lower:
            ticker_filter = "AMZN"
        elif "google" in query_lower or "alphabet" in query_lower or "googl" in query_lower:
            ticker_filter = "GOOGL"

        from app.retrieval.types import SearchFilters
        filters = SearchFilters(ticker=ticker_filter) if ticker_filter else None
        
        passages = retriever.search(query, filters=filters, top_k=8)
        logger.info("hybrid_search_completed", thread_id=str(thread_id), retrieved_chunks=len(passages))
    except Exception as exc:
        logger.exception("hybrid_search_failed", thread_id=str(thread_id), error=str(exc))
        async for event in stream_error(f"Search retrieval failed: {exc}"):
            yield event
        return

    async for event in stream_status("reading", "Reading source passages…"):
        yield event

    grounded: GroundedAnswer | None = None
    validation = None

    for attempt in range(1, MAX_VALIDATION_ATTEMPTS + 1):
        logger.info("generation_attempt_started", thread_id=str(thread_id), attempt=attempt)
        
        # Hydrate the TurnRegistry allowlist to track the pre-retrieved database passages
        registry = TurnRegistry()
        registry.register_many(passages)
        
        context_text = format_passages_for_agent(passages)
        status_queue = asyncio.Queue()

        def on_status(stage: str, message: str) -> None:
            status_queue.put_nowait((stage, message))

        deps = DocumentAgentDeps(
            retriever=retriever,
            registry=registry,
            thread_id=thread_id,
            user_id=user.id,
            on_status=on_status,
        )
        
        # Native async task dispatch on main loop, receiving pre-retrieved context
        agent_task = asyncio.create_task(
            run_document_agent(query, context_text, deps)
        )

        try:
            logger.info("awaiting_agent_task", thread_id=str(thread_id), attempt=attempt)
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