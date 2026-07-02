"""SentenceTransformer embedding generation for document chunks."""

from __future__ import annotations

from sentence_transformers import SentenceTransformer
from app.config import settings

EMBED_BATCH_SIZE = 100
_model: SentenceTransformer | None = None


def _get_model() -> SentenceTransformer:
    global _model
    if _model is None:
        _model = SentenceTransformer(settings.openai_embedding_model)
    return _model


def embed_texts(texts: list[str], *, batch_size: int = EMBED_BATCH_SIZE) -> list[list[float]]:
    if not texts:
        return []

    expected_dims = settings.openai_embedding_dimensions
    model = _get_model()

    embeddings = model.encode(texts, batch_size=batch_size, show_progress_bar=False)
    vectors: list[list[float]] = []
    for emb in embeddings:
        vector = [float(x) for x in emb]
        if len(vector) != expected_dims:
            raise ValueError(
                f"Expected embedding dimension {expected_dims}, got {len(vector)}"
            )
        vectors.append(vector)

    return vectors
