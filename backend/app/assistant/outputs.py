"""Structured output types for the document agent."""

from __future__ import annotations

from pydantic import BaseModel, Field


class Citation(BaseModel):
    citation_index: int = Field(
        description="The 1-based index (e.g. 1, 2, 3)"
    )
    chunk_id: str = Field(
        description="The exact UUID string found inside the brackets [...] of the cited chunk. Copy it character-for-character. Do not alter a single letter."
    )
    excerpt: str = Field(
        description="Verbatim substring from the chunk text"
    )


class GroundedAnswer(BaseModel):
    answer: str = Field(description="The answer text containing inline [n] markers")
    citations: list[Citation] = Field(
        default_factory=list,
        description="The array of citations supporting the answer",
    )
    insufficient_evidence: bool = Field(
        default=False,
        description="True ONLY if the documents do not contain enough evidence",
    )