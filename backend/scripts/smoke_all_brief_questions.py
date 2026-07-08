"""Batch-execute and audit all 10 standard analyst questions from your client brief."""

from __future__ import annotations

import asyncio
import argparse
import sys
import uuid
from pathlib import Path

# Add backend root to sys.path for direct script execution
sys.path.append(str(Path(__file__).resolve().parents[1]))

from app.assistant.agent import run_document_agent
from app.assistant.deps import DocumentAgentDeps, TurnRegistry
from app.grounding.validator import GroundingValidator
from app.retrieval.retriever import DocumentRetriever
from app.retrieval.types import format_passages_for_agent, SearchFilters

QUESTIONS = [
    (
        1,
        "Across Apple's 2021–2025 10-Ks, how did the revenue mix between iPhone, Services, Mac, and iPad change, "
        "and which category appears to have contributed most to any mix shift?",
        "AAPL",
    ),
    (
        2,
        "For Amazon, compare AWS operating income and margin against North America and International from 2021–2025. "
        "In which years did AWS appear to fund losses or weaker profitability elsewhere?",
        "AMZN",
    ),
    (
        3,
        "How did NVIDIA describe demand drivers, customer concentration, and supply constraints for its Data Center business "
        "from fiscal 2021 through fiscal 2025?",
        "NVDA",
    ),
    (
        4,
        "Across Microsoft's 2021–2025 filings, what changed in the way the company describes Azure, AI infrastructure, "
        "and cloud capacity constraints?",
        "MSFT",
    ),
    (
        5,
        "For Alphabet, how did Google Search, YouTube ads, Google Network, subscriptions/platforms/devices, and Google Cloud "
        "revenue trends differ across the available 10-Ks?",
        "GOOGL",
    ),
    (
        6,
        "Which of the five companies added, removed, or materially changed risk-factor language related to AI, cloud infrastructure, "
        "export controls, supply chain concentration, or regulation between 2021 and 2025?",
        None,  # Cross-company lookup (no ticker restriction)
    ),
    (
        7,
        "For Apple and NVIDIA, what do the filings say about supplier concentration or dependence on third-party manufacturing, "
        "and did the wording become more or less urgent over time?",
        None,  # Cross-company lookup
    ),
    (
        8,
        "Compare capital expenditures and purchase commitments for Microsoft, Alphabet, Amazon, and NVIDIA. "
        "What do the filings imply about the scale and timing of AI/cloud infrastructure investment?",
        None,  # Cross-company lookup
    ),
    (
        9,
        "For each company, summarize the most important geographic revenue exposures disclosed in the latest 10-K, "
        "then identify any year-over-year changes that could matter to an analyst.",
        None,  # Cross-company lookup
    ),
    (
        10,
        "If an analyst asks whether the filings prove that generative AI improved margins for any of these companies, "
        "what evidence exists in the corpus, and where should the bot refuse to infer beyond the filings?",
        None,  # Cross-company lookup
    ),
]


async def execute_question(index: int, query: str, ticker: str | None, output_file=None):
    print("\n" + "="*80)
    print(f"QUESTION {index}: {query}")
    print(f"Ticker Filter: {ticker or 'Cross-Company'}")
    print("="*80, flush=True)

    # 1. Run direct hybrid SQL retrieval
    print("  -> Retrieving matching source database chunks...", end="", flush=True)
    retriever = DocumentRetriever()
    filters = SearchFilters(ticker=ticker) if ticker else None
    
    try:
        passages = retriever.search(query, filters=filters, top_k=8)
        print(f" OK (Retrieved {len(passages)} passages)", flush=True)
    except Exception as e:
        print(f" FAILED: {e}", flush=True)
        return False

    if not passages:
        print("  -> WARNING: No matching chunks found. Proceeding with empty context.", flush=True)

    # 2. Setup Registries and Context wrappers
    registry = TurnRegistry()
    registry.register_many(passages)
    context_text = format_passages_for_agent(passages)

    deps = DocumentAgentDeps(
        retriever=retriever,
        registry=registry,
        thread_id=uuid.uuid4(),
        user_id=uuid.uuid4(),
    )

    # 3. Call PydanticAI / Llama Async execution loop
    print("  -> Contacting Groq Cloud / Llama 3.3 for grounded synthesis...", end="", flush=True)
    try:
        answer = await run_document_agent(query, context_text, deps)
        print(" OK", flush=True)
    except Exception as e:
        print(f" FAILED: {e}", flush=True)
        return False

    # 4. Execute post-agent grounding validator
    print("  -> Running Grounding Validation and auto-healer checks...", end="", flush=True)
    validator = GroundingValidator()
    validation = await validator.validate(answer, registry)
    print(f" DONE (Result: ok={validation.ok})", flush=True)

    # Format results output
    result_block = []
    result_block.append(f"\n==================================================")
    result_block.append(f"QUESTION {index} RESULTS:")
    result_block.append(f"Query: {query}")
    result_block.append(f"Validation OK: {validation.ok}")
    if validation.error:
        result_block.append(f"Validation Error: {validation.error}")
    result_block.append(f"Insufficient Evidence: {answer.insufficient_evidence}")
    result_block.append(f"Total Citations Attached: {len(answer.citations)}")
    result_block.append(f"==================================================")
    result_block.append(f"\nAnswer:\n{answer.answer}\n")
    
    if answer.citations:
        result_block.append("Citations:")
        for citation in answer.citations:
            passage = registry.passages_by_chunk_id.get(uuid.UUID(citation.chunk_id))
            source = f"{passage.ticker} {passage.form} p.{passage.page or 'N/A'}" if passage else "Unknown Source"
            result_block.append(f"  [{citation.citation_index}] Source: {source}")
            result_block.append(f"      Excerpt: \"{citation.excerpt}\"")
    result_block.append("\n" + "-"*50 + "\n")

    formatted_text = "\n".join(result_block)
    print(formatted_text, flush=True)

    if output_file:
        with open(output_file, "a", encoding="utf-8") as f:
            f.write(formatted_text)

    return validation.ok


async def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--question",
        type=int,
        choices=range(1, 11),
        help="Run a single question by its index (1 to 10) to preserve rate-limits.",
    )
    parser.add_argument(
        "--all",
        action="store_true",
        help="Run the complete suite of all 10 questions sequentially.",
    )
    args = parser.parse_args()

    if not args.question and not args.all:
        parser.print_help()
        print("\nExample: uv run python scripts/smoke_all_brief_questions.py --question 1")
        return

    output_file = Path("scratch/smoke_all_results.txt")
    output_file.parent.mkdir(parents=True, exist_ok=True)

    # Initialize or wipe output file on new run
    if args.all:
        output_file.write_text("=== COMPLETE DRIFTWOOD CO-PILOT BATCH VERIFICATION ===\n\n", encoding="utf-8")
        print("Running full Driftwood verification suite sequentially. Standard rate-limit delays will be applied.")
        success_count = 0
        for index, query, ticker in QUESTIONS:
            ok = await execute_question(index, query, ticker, output_file)
            if ok:
                success_count += 1
            # Apply a 5-second sleep delay to protect the Groq API quota
            await asyncio.sleep(5)
        
        print("\n" + "="*80)
        print(f"BATCH COMPLETED: {success_count}/10 questions successfully synthesized and grounded!")
        print(f"Full results transcript committed to: {output_file}")
        print("="*80)
    else:
        # Run single question selectively
        index, query, ticker = next(q for q in QUESTIONS if q[0] == args.question)
        await execute_question(index, query, ticker)


if __name__ == "__main__":
    asyncio.run(main())