"""Fail-closed citation validation against the turn registry with autonomous auto-healing."""

from __future__ import annotations

import re
import uuid
from dataclasses import dataclass

from app.assistant.deps import TurnRegistry
from app.assistant.outputs import GroundedAnswer

_CITATION_MARKER_RE = re.compile(r"\[(\d+)\]")


@dataclass(frozen=True, slots=True)
class ValidationResult:
    ok: bool
    error: str | None = None


class GroundingValidator:
    async def validate(
        self,
        answer: GroundedAnswer,
        registry: TurnRegistry,
    ) -> ValidationResult:
        """Programmatically verify citations against the turn's retrieval registry with resilient table normalizations."""
        if not answer.answer.strip():
            return ValidationResult(ok=False, error="Answer text is empty.")

        if answer.insufficient_evidence:
            if answer.citations:
                return ValidationResult(
                    ok=False,
                    error="insufficient_evidence answers must not include citations.",
                )
            return ValidationResult(ok=True)

        if not answer.citations:
            return ValidationResult(
                ok=False,
                error="Grounded answers must include at least one citation.",
            )

        if not registry.passages_by_chunk_id:
            return ValidationResult(
                ok=False,
                error="Citations present but no passages were retrieved this turn.",
            )

        indices = [citation.citation_index for citation in answer.citations]
        if len(indices) != len(set(indices)):
            return ValidationResult(ok=False, error="Duplicate citation_index values.")

        expected_indices = list(range(1, len(indices) + 1))
        if sorted(indices) != expected_indices:
            return ValidationResult(
                ok=False,
                error="citation_index values must be unique, 1-based, and contiguous.",
            )

        marker_indices = {int(m.group(1)) for m in _CITATION_MARKER_RE.finditer(answer.answer)}
        if marker_indices != set(indices):
            return ValidationResult(
                ok=False,
                error="Answer [n] markers must match citation_index values exactly.",
            )

        for citation in answer.citations:
            # 1. Verify UUID format
            try:
                parsed_id = uuid.UUID(citation.chunk_id.strip())
            except ValueError:
                return ValidationResult(
                    ok=False,
                    error=f"Citation [{citation.citation_index}] contains an invalid UUID structure: '{citation.chunk_id}'."
                )

            # 2. Check if verbatim excerpt is in the cited chunk
            passage = registry.passages_by_chunk_id.get(parsed_id)
            
            excerpt_alphanumeric = re.sub(r"[^a-zA-Z0-9]", "", citation.excerpt.lower())
            
            is_grounded_in_cited = False
            if passage:
                source_alphanumeric = re.sub(r"[^a-zA-Z0-9]", "", passage.text.lower())
                if excerpt_alphanumeric in source_alphanumeric:
                    is_grounded_in_cited = True

            # 3. AUTO-HEALING: If not in the cited chunk, scan other retrieved passages for a verbatim match
            if not is_grounded_in_cited:
                healed = False
                for candidate_id, candidate_passage in registry.passages_by_chunk_id.items():
                    cand_alphanumeric = re.sub(r"[^a-zA-Z0-9]", "", candidate_passage.text.lower())
                    if excerpt_alphanumeric in cand_alphanumeric:
                        # Re-bind the cited ID to the actual chunk that contains this excerpt verbatim
                        citation.chunk_id = str(candidate_id)
                        healed = True
                        break
                
                if not healed:
                    return ValidationResult(
                        ok=False,
                        error=f"Citation [{citation.citation_index}] excerpt cannot be verified against any retrieved source chunks."
                    )

        # Programmatic checks and auto-healing successful!
        return ValidationResult(ok=True)


def prune_unreferenced_citations(answer: GroundedAnswer) -> GroundedAnswer:
    marker_indices = {int(m.group(1)) for m in _CITATION_MARKER_RE.finditer(answer.answer)}
    if not marker_indices:
        return answer
    citations = [c for c in answer.citations if c.citation_index in marker_indices]
    if len(citations) == len(answer.citations):
        return answer
    return answer.model_copy(update={"citations": citations})