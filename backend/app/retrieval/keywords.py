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


def _get_base_url() -> str | None:
    if settings.openai_api_key.startswith("gsk_"):
        return "https://api.groq.com/openai/v1"
    return None


def _client() -> OpenAI:
    return OpenAI(
        api_key=settings.openai_api_key,
        base_url=_get_base_url(),
    )


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