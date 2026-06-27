"""SQLAlchemy table models — import all models so Alembic autogenerate sees metadata."""

from app.database.base import Base
from app.database.models.chat_messages import ChatMessage, MessageRole
from app.database.models.chat_threads import ChatThread
from app.database.models.document_chunks import DocumentChunk
from app.database.models.message_citations import MessageCitation
from app.database.models.source_documents import SourceDocument
from app.database.models.users import User

__all__ = [
    "Base",
    "ChatMessage",
    "ChatThread",
    "DocumentChunk",
    "MessageCitation",
    "MessageRole",
    "SourceDocument",
    "User",
]
