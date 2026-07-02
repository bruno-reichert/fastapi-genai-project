"""make_search_vector_generated_column

Revision ID: 065a6e238376
Revises: d34453dede40
Create Date: 2026-07-02 15:41:19.663089

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

# revision identifiers, used by Alembic.
revision: str = '065a6e238376'
down_revision: Union[str, Sequence[str], None] = 'd34453dede40'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # 1. Drop the manual column
    op.drop_column('document_chunks', 'search_vector')

    # 2. Add search_vector as a Postgres generated column pointing to 'content'
    op.execute(
        """
        ALTER TABLE document_chunks
        ADD COLUMN search_vector tsvector
        GENERATED ALWAYS AS (to_tsvector('english', content)) STORED
        """
    )

    # 3. Create a high-performance GIN index on the generated search vector
    op.execute(
        """
        CREATE INDEX ix_document_chunks_search_vector_gin
        ON document_chunks
        USING gin (search_vector)
        """
    )


def downgrade() -> None:
    # 1. Drop the index
    op.execute("DROP INDEX IF EXISTS ix_document_chunks_search_vector_gin")

    # 2. Drop the generated column
    op.drop_column('document_chunks', 'search_vector')

    # 3. Restore the standard nullable column
    op.add_column(
        'document_chunks',
        sa.Column('search_vector', postgresql.TSVECTOR(), nullable=True)
    )