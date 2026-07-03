"""Fail-closed citation validation against the turn registry."""

from __future__ import annotations

import asyncio
import json
import re
import uuid
from dataclasses import dataclass
from typing import Any

from openai import OpenAI
from pydantic import BaseModel, Field

from app.assistant.deps import TurnRegistry
from app.assistant.outputs import GroundedAnswer
from app.config import settings

_CITATION_MARKER_RE = re.compile(r"\[(\d+)\]")

_GROUNDING_JUDGE_SYSTEM_PROMPT = """\
You are a strict grounding validator for SEC filing answers.
Your task is to decide whether each answer claim identified by a citation marker is supported by the retrieved source chunk for that citation.

You must return a JSON object containing a "decisions" array. Each item inside "decisions" must be a JSON object with:
- "citation_index": int (matching the case citation_index)
- "supported": bool (true if fully supported, false if partial, ambiguous, or absent)
- "reason": str (short reason for the grounding decision)

Strictly output valid JSON matching this schema:
{
  "decisions": [
    {
      "citation_index": 1,
      "supported": true,
      "reason": "..."
    }
  ]
}
"""


@dataclass(frozen=True, slots=True)
class ValidationResult:
    ok: bool
    error: str | None = None


class CitationGroundingCase(BaseModel):
    citation_index: int
    answer: str
    excerpt: str
    source_text: str


class CitationGroundingDecision(BaseModel):
    citation_index: int
    supported: bool
    reason: str


class GroundingValidator:
    def __init__(self) -> None:
        self._client = OpenAI(
            api_key=settings.openai_api_key,
            base_url=self._get_base_url(),
        )

    def _get_base_url(self) -> str | None:
        if settings.openai_api_key.startswith("gsk_"):
            return "https://api.groq.com/openai/v1"
        return None

    async def validate(
        self,
        answer: GroundedAnswer,
        registry: TurnRegistry,
    ) -> ValidationResult:
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

        # DIAGNOSTICS: Print out all active keys registered in memory
        print("\n" + "-"*50)
        print(f"DIAGNOSTIC - TurnRegistry has {len(registry.passages_by_chunk_id)} registered keys:")
        for chunk_id, passage in registry.passages_by_chunk_id.items():
            print(f"  * {chunk_id} ({passage.ticker} {passage.form} index={passage.chunk_index})")
        print("-"*50 + "\n")

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

        cases: list[CitationGroundingCase] = []
        for citation in answer.citations:
            # Safely parse the string to UUID format
            try:
                parsed_id = uuid.UUID(citation.chunk_id.strip())
            except ValueError:
                return ValidationResult(
                    ok=False,
                    error=f"Citation [{citation.citation_index}] contains an invalid UUID structure: '{citation.chunk_id}'."
                )

            passage = registry.passages_by_chunk_id.get(parsed_id)
            if passage is None:
                return ValidationResult(
                    ok=False,
                    error=f"Citation [{citation.citation_index}] references chunk ID {parsed_id} that was not retrieved.",
                )

            # Verbatim case-insensitive substring verification
            excerpt_clean = " ".join(citation.excerpt.lower().split())
            source_clean = " ".join(passage.text.lower().split())
            if excerpt_clean not in source_clean:
                return ValidationResult(
                    ok=False,
                    error=f"Citation [{citation.citation_index}] excerpt is not a verbatim substring of the cited source chunk."
                )

            cases.append(
                CitationGroundingCase(
                    citation_index=citation.citation_index,
                    answer=answer.answer,
                    excerpt=citation.excerpt,
                    source_text=passage.text,
                )
            )

        try:
            decisions = await asyncio.to_thread(self._judge_sync, cases)
        except Exception as exc:
            return ValidationResult(
                ok=False,
                error=f"Grounding judge failed: {exc}",
            )

        decision_by_index = {d["citation_index"]: d for d in decisions}
        for citation_index in indices:
            decision = decision_by_index.get(citation_index)
            if not decision:
                return ValidationResult(
                    ok=False,
                    error=f"Missing decision for citation index {citation_index}.",
                )
            if not decision.get("supported"):
                return ValidationResult(
                    ok=False,
                    error=(
                        f"Citation [{citation_index}] is not supported by retrieved "
                        f"source text: {decision.get('reason')}"
                    ),
                )

        return ValidationResult(ok=True)

    def _judge_sync(self, cases: list[CitationGroundingCase]) -> list[dict[str, Any]]:
        response = self._client.chat.completions.create(
            model=settings.openai_model_name,
            temperature=0,
            response_format={"type": "json_object"},
            messages=[
                {"role": "system", "content": _GROUNDING_JUDGE_SYSTEM_PROMPT},
                {
                    "role": "user",
                    "content": json.dumps(
                        {"cases": [case.model_dump(mode="json") for case in cases]},
                        separators=(",", ":"),
                    ),
                },
            ],
        )
        payload = json.loads(response.choices[0].message.content or "{}")
        return payload.get("decisions", [])


def prune_unreferenced_citations(answer: GroundedAnswer) -> GroundedAnswer:
    marker_indices = {int(m.group(1)) for m in _CITATION_MARKER_RE.finditer(answer.answer)}
    if not marker_indices:
        return answer
    citations = [c for c in answer.citations if c.citation_index in marker_indices]
    if len(citations) == len(answer.citations):
        return answer
    return answer.model_copy(update={"citations": citations})