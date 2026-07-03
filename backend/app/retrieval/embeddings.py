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
