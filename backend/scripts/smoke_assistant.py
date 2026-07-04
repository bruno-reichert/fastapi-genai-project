"""Run a standalone agent turn locally to test the retrieval, tools, and grounding layers."""

from __future__ import annotations

import asyncio
import uuid

from app.assistant.agent import run_document_agent
from app.assistant.deps import DocumentAgentDeps, TurnRegistry
from app.grounding.validator import GroundingValidator
from app.retrieval.retriever import DocumentRetriever

QUERY = "Across Apple's recent 10-Ks, what did they say about Services net sales growth and its primary drivers?"


async def test_agent_turn():
    print(f"Initiating stand-alone agent smoke test...")
    print(f"Query: '{QUERY}'\n")

    registry = TurnRegistry()
    retriever = DocumentRetriever()

    def on_status(stage: str, message: str) -> None:
        print(f"  [Pipeline Status] {stage.upper()}: {message}")

    deps = DocumentAgentDeps(
        retriever=retriever,
        registry=registry,
        thread_id=uuid.uuid4(),
        user_id=uuid.uuid4(),
        on_status=on_status,
    )

    # 1. Execute the agent run
    print("Executing PydanticAI Agent...")
    answer = await asyncio.to_thread(run_document_agent, QUERY, deps)

    # 2. Execute grounding validation
    print("\nExecuting Grounding Validation...")
    validator = GroundingValidator()
    validation = await validator.validate(answer, registry)

    print("\n" + "=" * 80)
    print("RESULTS:")
    print(f"  Validation OK: {validation.ok}")
    if validation.error:
        print(f"  Validation Error: {validation.error}")
    print(f"  Insufficient Evidence: {answer.insufficient_evidence}")
    print(f"  Total Citations: {len(answer.citations)}")
    print("=" * 80)

    print(f"\nAnswer:\n{answer.answer}\n")

    if answer.citations:
        print("Citations:")
        for citation in answer.citations:
            # Safely parse the string chunk_id to UUID to match the registry dictionary keys
            try:
                parsed_id = uuid.UUID(citation.chunk_id.strip())
                passage = registry.passages_by_chunk_id.get(parsed_id)
            except ValueError:
                passage = None

            source = f"{passage.ticker} {passage.form} p.{passage.page}" if passage else "Unknown Source"
            print(f"  [{citation.citation_index}] Source: {source}")
            print(f"      Excerpt: \"{citation.excerpt}\"")


if __name__ == "__main__":
    asyncio.run(test_agent_turn())