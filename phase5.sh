# Execute from your repository root
cat << 'EOF' > setup_backend_retrieval.sh
#!/bin/bash
set -e

# Create directories
mkdir -p backend/app/retrieval
mkdir -p backend/scripts

# 1. Create app/database/documents.py (for database chunk hydration)
cat << 'INNER_EOF' > backend/app/database/documents.py
"""Chunk and source-document lookups for retrieval and agent tools."""

from __future__ import annotations

from uuid import UUID

from sqlalchemy import select
from sqlalchemy.orm import Session, joinedload

from app.database.models import DocumentChunk, SourceDocument


def get_chunks_by_ids(
    session: Session,
    chunk_ids: list[UUID],
) -> dict[UUID, DocumentChunk]:
    if not chunk_ids:
        return {}

    rows = session.scalars(
        select(DocumentChunk)
        .options(joinedload(DocumentChunk.source_document))
        .where(DocumentChunk.id.in_(chunk_ids))
    ).all()
    return {row.id: row for row in rows}


def get_chunk_with_document(
    session: Session,
    chunk_id: UUID,
) -> tuple[DocumentChunk, SourceDocument] | None:
    chunk = session.scalar(
        select(DocumentChunk)
        .options(joinedload(DocumentChunk.source_document))
        .where(DocumentChunk.id == chunk_id)
    )
    if chunk is None or chunk.source_document is None:
        return None
    return chunk, chunk.source_document


def get_surrounding_chunks(
    session: Session,
    chunk_id: UUID,
    radius: int,
) -> list[DocumentChunk]:
    if radius < 1:
        return []

    anchor = session.scalar(
        select(DocumentChunk).where(DocumentChunk.id == chunk_id)
    )
    if anchor is None:
        return []

    min_index = anchor.chunk_index - radius
    max_index = anchor.chunk_index + radius
    return list(
        session.scalars(
            select(DocumentChunk)
            .options(joinedload(DocumentChunk.source_document))
            .where(
                DocumentChunk.source_document_id == anchor.source_document_id,
                DocumentChunk.chunk_index >= min_index,
                DocumentChunk.chunk_index <= max_index,
                DocumentChunk.id != chunk_id,
            )
            .order_by(DocumentChunk.chunk_index)
        ).all()
    )


def get_chunk_context(
    session: Session,
    chunk_id: UUID,
    radius: int,
) -> list[DocumentChunk] | None:
    anchor = session.scalar(
        select(DocumentChunk)
        .options(joinedload(DocumentChunk.source_document))
        .where(DocumentChunk.id == chunk_id)
    )
    if anchor is None:
        return None

    min_index = anchor.chunk_index - radius
    max_index = anchor.chunk_index + radius
    return list(
        session.scalars(
            select(DocumentChunk)
            .options(joinedload(DocumentChunk.source_document))
            .where(
                DocumentChunk.source_document_id == anchor.source_document_id,
                DocumentChunk.chunk_index >= min_index,
                DocumentChunk.chunk_index <= max_index,
            )
            .order_by(DocumentChunk.chunk_index)
        ).all()
    )
INNER_EOF

# 2. Create app/retrieval/types.py
cat << 'INNER_EOF' > backend/app/retrieval/types.py
"""Pydantic models shared by retrieval and future agent tools."""

from __future__ import annotations

from datetime import date
from uuid import UUID

from pydantic import BaseModel, Field

MAX_PASSAGE_EXCERPT_CHARS = 800
MAX_AGENT_OUTPUT_CHARS = 12_000


class SearchFilters(BaseModel):
    ticker: str | None = None
    fiscal_years: list[int] | None = None
    form: str | None = None


class RankedChunkHit(BaseModel):
    chunk_id: UUID
    rank: int
    score: float | None = None


class RetrievedPassage(BaseModel):
    chunk_id: UUID
    document_id: UUID
    chunk_index: int
    text: str
    page: str | None
    section: str | None
    fusion_score: float
    ticker: str
    company_name: str | None
    form: str
    filing_date: date
    fiscal_year: int | None
    accession_number: str
    neighbors: list[RetrievedPassage] = Field(default_factory=list)


def _format_one_passage(passage: RetrievedPassage, *, include_neighbors: bool) -> str:
    year = passage.fiscal_year or passage.filing_date.year
    page = f" p.{passage.page}" if passage.page else ""
    section = f" ({passage.section})" if passage.section else ""
    excerpt = passage.text.strip()
    if len(excerpt) > MAX_PASSAGE_EXCERPT_CHARS:
        excerpt = excerpt[:MAX_PASSAGE_EXCERPT_CHARS] + "..."
    header = (
        f"{passage.ticker} {passage.form} FY{year}{page}{section} "
        f"[{passage.chunk_id}]: {excerpt}"
    )
    lines = [header]
    if include_neighbors:
        for neighbor in passage.neighbors:
            neighbor_excerpt = neighbor.text.strip()
            if len(neighbor_excerpt) > MAX_PASSAGE_EXCERPT_CHARS:
                neighbor_excerpt = neighbor_excerpt[:MAX_PASSAGE_EXCERPT_CHARS] + "..."
            lines.append(
                f"  neighbor idx={neighbor.chunk_index} [{neighbor.chunk_id}]: {neighbor_excerpt}"
            )
    return "\n".join(lines)


def format_passages_for_agent(passages: list[RetrievedPassage]) -> str:
    """Bounded, grep-style text for agent tool responses."""
    if not passages:
        return "No matching passages found in the filing corpus."

    blocks = [_format_one_passage(p, include_neighbors=True) for p in passages]
    output = "\n\n".join(blocks)
    if len(output) > MAX_AGENT_OUTPUT_CHARS:
        output = (
            output[:MAX_AGENT_OUTPUT_CHARS]
            + f"\n... truncated to {len(passages)} passages."
        )
    return output
INNER_EOF

# 3. Create app/retrieval/embeddings.py (live search queries using local encoder)
cat << 'INNER_EOF' > backend/app/retrieval/embeddings.py
"""Local query embedding generation using SentenceTransformer."""

from __future__ import annotations

from sentence_transformers import SentenceTransformer
from app.config import settings

_model: SentenceTransformer | None = None


def _get_model() -> SentenceTransformer:
    global _model
    if _model is None:
        _model = SentenceTransformer(settings.openai_embedding_model)
    return _model


def embed_query(text: str) -> list[float]:
    model = _get_model()
    emb = model.encode(text, show_progress_bar=False)
    embedding = [float(x) for x in emb]
    expected_dims = settings.openai_embedding_dimensions
    if len(embedding) != expected_dims:
        raise ValueError(
            f"Expected embedding dimension {expected_dims}, got {len(embedding)}"
        )
    return embedding
INNER_EOF

# 4. Create app/retrieval/keywords.py (distilling queries with Llama 3.3)
cat << 'INNER_EOF' > backend/app/retrieval/keywords.py
"""LLM keyword extraction for Postgres full-text search."""

from __future__ import annotations

import json
import re
from openai import OpenAI

from app.config import settings
from app.retrieval.types import SearchFilters

_FILLER_WORDS = frozenset(
    {
        "a", "an", "and", "across", "are", "as", "at", "be", "between", "by", "change",
        "changed", "describe", "describes", "described", "did", "do", "for", "from",
        "how", "in", "into", "is", "its", "of", "on", "or", "the", "their", "they",
        "this", "to", "was", "way", "what", "when", "where", "which", "who", "with",
    }
)

_SYSTEM_PROMPT = """\
You are an expert keyword extraction assistant. 
Your task is to extract search keywords for a PostgreSQL full-text search over SEC filing database chunks.

Given a user's natural language question, return a JSON object with a "terms" array containing 3 to 5 highly relevant search terms.
- Focus on domain nouns and standard two-word financial/SEC phrases (e.g. "data center", "revenue mix").
- Omit conversational filler, generic verbs, and punctuation.
- Preserve uppercase casing for product/brand names (e.g., "Azure", "iPhone").
- Return strictly valid JSON matching this schema:
{
  "terms": ["term1", "term2", "term3"]
}
"""


def _client() -> OpenAI:
    return OpenAI(api_key=settings.openai_api_key)


def _token_count(query: str) -> int:
    return len(query.split())


def _build_user_message(query: str, filters: SearchFilters | None) -> str:
    parts = [f"Query: {query}"]
    if filters is not None and filters.ticker is not None:
        parts.append(f"Ticker filter: {filters.ticker} (omit company name from terms)")
    return "\n".join(parts)


def _deterministic_fallback(query: str) -> str:
    tokens = re.findall(r"[A-Za-z0-9][A-Za-z0-9\-/]*", query)
    kept = [t for t in tokens if t.casefold() not in _FILLER_WORDS]
    if not kept:
        return query.strip()
    return " ".join(kept[:5])


def extract_fts_keywords(
    query: str,
    *,
    filters: SearchFilters | None = None,
) -> str:
    """Return a space-joined keyword string for plainto_tsquery."""
    stripped = query.strip()
    if not stripped:
        return stripped

    # Fast path for short keyword-like queries
    if _token_count(stripped) <= 5:
        return stripped

    try:
        response = _client().chat.completions.create(
            model=settings.openai_model_name,
            temperature=0,
            response_format={"type": "json_object"},
            messages=[
                {"role": "system", "content": _SYSTEM_PROMPT},
                {"role": "user", "content": _build_user_message(stripped, filters)},
            ],
        )
        payload = json.loads(response.choices[0].message.content or "{}")
        terms = payload.get("terms", [])
        if not terms or not isinstance(terms, list):
            return _deterministic_fallback(stripped)

        # Sanitize and limit
        sanitized = [t.strip() for t in terms if t.strip()]
        if not sanitized:
            return _deterministic_fallback(stripped)
        return " ".join(sanitized[:5])
    except Exception:
        return _deterministic_fallback(stripped)
INNER_EOF

# 5. Create app/retrieval/queries.py (Vector and Lexical SQL queries)
cat << 'INNER_EOF' > backend/app/retrieval/queries.py
"""pgvector semantic search and Postgres full-text search over document_chunks."""

from __future__ import annotations

from dataclasses import dataclass
from uuid import UUID

from sqlalchemy import text
from sqlalchemy.orm import Session

from app.retrieval.types import RankedChunkHit, SearchFilters


@dataclass(frozen=True, slots=True)
class _FilterClause:
    sql: str
    params: dict[str, object]


def _vector_literal(values: list[float]) -> str:
    return "[" + ",".join(str(v) for v in values) + "]"


def _build_filters(filters: SearchFilters | None) -> _FilterClause:
    if filters is None:
        return _FilterClause("", {})

    clauses: list[str] = []
    params: dict[str, object] = {}

    if filters.ticker is not None:
        clauses.append("sd.ticker = :ticker")
        params["ticker"] = filters.ticker
    if filters.fiscal_years:
        clauses.append("sd.filing_date >= :start_date AND sd.filing_date <= :end_date")
        # In this simplified database, we map years directly to filing date ranges
        params["start_date"] = f"{min(filters.fiscal_years)}-01-01"
        params["end_date"] = f"{max(filters.fiscal_years)}-12-31"
    if filters.form is not None:
        clauses.append("sd.form = :form")
        params["form"] = filters.form

    if not clauses:
        return _FilterClause("", {})

    return _FilterClause(" AND " + " AND ".join(clauses), params)


def _rows_to_hits(rows: list) -> list[RankedChunkHit]:
    return [
        RankedChunkHit(
            chunk_id=UUID(str(row.id)),
            rank=index,
            score=float(row.score) if row.score is not None else None,
        )
        for index, row in enumerate(rows, start=1)
    ]


def semantic_search(
    session: Session,
    query_vec: list[float],
    *,
    limit: int,
    filters: SearchFilters | None = None,
) -> list[RankedChunkHit]:
    filter_clause = _build_filters(filters)
    sql = f"""
        SELECT dc.id,
               1 - (dc.embedding <=> CAST(:query_vec AS vector)) AS score
        FROM document_chunks dc
        JOIN source_documents sd ON sd.id = dc.source_document_id
        WHERE dc.embedding IS NOT NULL
        {filter_clause.sql}
        ORDER BY dc.embedding <=> CAST(:query_vec AS vector)
        LIMIT :limit
    """
    params: dict[str, object] = {
        "query_vec": _vector_literal(query_vec),
        "limit": limit,
        **filter_clause.params,
    }
    rows = session.execute(text(sql), params).all()
    return _rows_to_hits(rows)


def full_text_search(
    session: Session,
    query_text: str,
    *,
    limit: int,
    filters: SearchFilters | None = None,
) -> list[RankedChunkHit]:
    filter_clause = _build_filters(filters)
    sql = f"""
        SELECT dc.id,
               ts_rank_cd(dc.search_vector, query) AS score
        FROM document_chunks dc
        JOIN source_documents sd ON sd.id = dc.source_document_id,
             plainto_tsquery('english', :query_text) query
        WHERE dc.search_vector @@ query
        {filter_clause.sql}
        ORDER BY score DESC
        LIMIT :limit
    """
    params: dict[str, object] = {
        "query_text": query_text,
        "limit": limit,
        **filter_clause.params,
    }
    rows = session.execute(text(sql), params).all()
    return _rows_to_hits(rows)
INNER_EOF

# 6. Create app/retrieval/fusion.py (Python-based RRF)
cat << 'INNER_EOF' > backend/app/retrieval/fusion.py
"""Reciprocal Rank Fusion for hybrid retrieval."""

from __future__ import annotations

from collections import defaultdict
from uuid import UUID


def reciprocal_rank_fusion(
    rankings: list[list[UUID]],
    *,
    k: int = 60,
) -> list[tuple[UUID, float]]:
    scores: dict[UUID, float] = defaultdict(float)
    for ranking in rankings:
        for rank, chunk_id in enumerate(ranking, start=1):
            scores[chunk_id] += 1.0 / (k + rank)
    return sorted(scores.items(), key=lambda item: -item[1])
INNER_EOF

# 7. Create app/retrieval/retriever.py (Master Retriever orchestration)
cat << 'INNER_EOF' > backend/app/retrieval/retriever.py
"""Hybrid retrieval orchestrator: embed/keywords -> parallel DB search -> fuse -> hydrate."""

from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
from uuid import UUID

from sqlalchemy.orm import Session

from app.database.documents import get_chunks_by_ids, get_surrounding_chunks
from app.database.session import get_session if "get_session" in dir() else None
from app.retrieval.embeddings import embed_query
from app.retrieval.fusion import reciprocal_rank_fusion
from app.retrieval.keywords import extract_fts_keywords
from app.retrieval.queries import full_text_search, semantic_search
from app.retrieval.types import RankedChunkHit, RetrievedPassage, SearchFilters

from app.database.models import DocumentChunk, SourceDocument

# Simple local session manager fallback if not explicitly in app database imports
if get_session is None:
    from sqlalchemy import create_engine
    from sqlalchemy.orm import sessionmaker
    from app.config import settings
    _engine = create_engine(settings.database_url)
    _SessionLocal = sessionmaker(bind=_engine)
    def get_session():
        return _SessionLocal()


class DocumentRetriever:
    def search(
        self,
        query: str,
        *,
        filters: SearchFilters | None = None,
        top_k: int = 10,
        candidate_k: int = 50,
        include_neighbors: bool = True,
        session: Session | None = None,
    ) -> list[RetrievedPassage]:
        if session is not None:
            return self._search_with_session(
                session,
                query,
                filters=filters,
                top_k=top_k,
                candidate_k=candidate_k,
                include_neighbors=include_neighbors,
            )

        with get_session() as owned_session:
            return self._search_with_session(
                owned_session,
                query,
                filters=filters,
                top_k=top_k,
                candidate_k=candidate_k,
                include_neighbors=include_neighbors,
            )

    def _search_with_session(
        self,
        session: Session,
        query: str,
        *,
        filters: SearchFilters | None,
        top_k: int,
        candidate_k: int,
        include_neighbors: bool,
    ) -> list[RetrievedPassage]:
        # 1. Run Query Embedding + Keyword extraction in parallel
        with ThreadPoolExecutor(max_workers=2) as prep_executor:
            embed_future = prep_command = prep.submit(embed_query_local, query) if 'embed_query' in globals() else prep.submit(embed_texts, [query])
            kw_future = prep.submit(extract_fts_keywords, query, filters=filters)
            query_vec = embed_future.result()[0]
            fts_query = kw_future.result()

        # 2. Run dual database queries in parallel
        semantic_hits, fts_hits = _dual_search(
            query_vec,
            fts_query,
            candidate_k=candidate_k,
            filters=filters,
        )

        # 3. Fuse ranked results
        semantic_ids = [hit.chunk_id for hit in semantic_hits]
        fts_ids = [hit.chunk_id for hit in fts_hits]
        fused = reciprocal_rank_fusion(
            [semantic_ids, fts_ids],
            k=60,
        )[:top_k]

        if not fused:
            return []

        # 4. Hydrate database structures
        fused_ids = [chunk_id for chunk_id, _ in fused]
        fusion_scores = {chunk_id: score for chunk_id, score in fused}
        chunks_by_id = get_chunks_by_ids(session, fused_ids)

        passages: list[RetrievedPassage] = []
        seen_neighbor_ids: set[UUID] = set(fused_ids)

        for chunk_id in fused_ids:
            chunk = chunks_by_id.get(chunk_id)
            if chunk is None or chunk.source_document is None:
                continue

            neighbors: list[RetrievedPassage] = []
            if include_neighbors:
                for neighbor_chunk in get_surrounding_chunks(
                    session,
                    chunk_id,
                    1, # Neighbour radius = 1
                ):
                    if neighbor_chunk.id in seen_neighbor_ids:
                        continue
                    if neighbor_chunk.source_document is None:
                        continue
                    seen_neighbor_ids.add(neighbor_chunk.id)
                    neighbors.append(
                        _passage_from_chunk(
                            neighbor_chunk,
                            neighbor_chunk.source_document,
                            fusion_score=0.0,
                        )
                    )

            passages.append(
                _passage_from_chunk(
                    chunk,
                    chunk.source_document,
                    fusion_score=fusion_scores[chunk_id],
                    neighbors=neighbors,
                )
            )

        return passages


def embed_query_local(query: str) -> list[list[float]]:
    from app.retrieval.embeddings import embed_query
    return [embed_query(query)]


def _dual_search(
    query_vec: list[float],
    fts_query: str,
    *,
    candidate_k: int,
    filters: SearchFilters | None,
) -> tuple[list[RankedChunkHit], list[RankedChunkHit]]:
    def semantic() -> list[RankedChunkHit]:
        with get_session() as search_session:
            return semantic_search(
                search_session,
                query_vec,
                limit=candidate_k,
                filters=filters,
            )

    def fts() -> list[RankedChunkHit]:
        with get_session() as search_session:
            return full_text_search(
                search_session,
                fts_query,
                limit=candidate_k,
                filters=filters,
            )

    with ThreadPoolExecutor(max_workers=2) as executor:
        semantic_future = executor.submit(semantic)
        fts_future = executor.submit(fts)
        return semantic_future.result(), fts_future.result()


def _passage_from_chunk(
    chunk: DocumentChunk,
    document: SourceDocument,
    *,
    fusion_score: float,
    neighbors: list[RetrievedPassage] | None = None,
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
        neighbors=neighbors or [],
    )
INNER_EOF

# 8. Create app/retrieval/__init__.py
cat << 'INNER_EOF' > backend/app/retrieval/__init__.py
from app.retrieval.retriever import DocumentRetriever
from app.retrieval.types import RetrievedPassage, SearchFilters

__all__ = ["DocumentRetriever", "RetrievedPassage", "SearchFilters"]
INNER_EOF

# 9. Create scripts/smoke_retrieval.py to test retrieval pipeline
cat << 'INNER_EOF' > backend/scripts/smoke_retrieval.py
"""Print top retrieval hits for sample queries. Run using: uv run python scripts/smoke_retrieval.py"""

from __future__ import annotations

from app.retrieval.retriever import DocumentRetriever
from app.retrieval.types import SearchFilters, format_passages_for_agent

SMOKE_QUERIES: list[tuple[str, SearchFilters | None]] = [
    (
        "Across Apple's 10-Ks, how did the revenue mix between iPhone, Services, Mac, and iPad change?",
        SearchFilters(ticker="AAPL"),
    ),
    (
        "How did NVIDIA describe demand drivers and customer concentration for its Data Center business?",
        SearchFilters(ticker="NVDA"),
    ),
]


def main() -> None:
    retriever = DocumentRetriever()
    for query, filters in SMOKE_QUERIES:
        print("\n" + "=" * 80)
        print(f"Query: {query}")
        if filters is not None:
            print(f"Filters: {filters.model_dump_json()}")
        passages = retriever.search(query, filters=filters, top_k=5)
        print(format_passages_for_agent(passages))


if __name__ == "__main__":
    main()
INNER_EOF

echo "Backend Retrieval setup complete! Clean up script."
rm setup_backend_retrieval.sh
EOF

# Execute the creation script
bash setup_backend_retrieval.sh