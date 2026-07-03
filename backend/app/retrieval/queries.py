"""pgvector semantic search and Postgres full-text search over document_chunks."""

from __future__ import annotations

from collections.abc import Sequence
from typing import Any
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
        params["start_date"] = f"{min(filters.fiscal_years)}-01-01"
        params["end_date"] = f"{max(filters.fiscal_years)}-12-31"
    if filters.form is not None:
        clauses.append("sd.form = :form")
        params["form"] = filters.form

    if not clauses:
        return _FilterClause("", {})

    return _FilterClause(" AND " + " AND ".join(clauses), params)


def _rows_to_hits(rows: Sequence[Any]) -> list[RankedChunkHit]:
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