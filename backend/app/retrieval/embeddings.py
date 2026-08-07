"""Lightweight query embedding generation using FastEmbed (ONNX) - Low RAM."""

from __future__ import annotations

from fastembed import TextEmbedding
from app.config import settings

_model: TextEmbedding | None = None


def _get_model() -> TextEmbedding:
    global _model
    if _model is None:
        # Uses sentence-transformers/all-MiniLM-L6-v2 via ONNX runtime (~150MB RAM instead of ~700MB)
        _model = TextEmbedding(model_name="sentence-transformers/all-MiniLM-L6-v2")
    return _model


def embed_query(text: str) -> list[float]:
    model = _get_model()
    # FastEmbed returns a generator of numpy arrays
    embeddings = list(model.embed([text]))
    embedding = [float(x) for x in embeddings[0]]
    
    expected_dims = settings.openai_embedding_dimensions
    if len(embedding) != expected_dims:
        raise ValueError(
            f"Expected embedding dimension {expected_dims}, got {len(embedding)}"
        )
    return embedding