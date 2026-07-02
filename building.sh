# Execute from your repository root
cat << 'EOF' > setup_backend_ingest.sh
#!/bin/bash
set -e

# Add tiktoken to backend dependencies
cd backend
uv add tiktoken
cd ..

# 1. Create backend/ingest/chunking.py
cat << 'INNER_EOF' > backend/ingest/chunking.py
"""Docling-based chunking for SEC HTML filings."""

from __future__ import annotations

import json
import re
from collections.abc import Iterator
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import tiktoken
from docling.chunking import HybridChunker
from docling.document_converter import DocumentConverter
from docling_core.transforms.chunker.hierarchical_chunker import (
    ChunkingDocSerializer,
    ChunkingSerializerProvider,
    HierarchicalChunker,
)
from docling_core.transforms.chunker.tokenizer.openai import OpenAITokenizer
from docling_core.transforms.serializer.markdown import (
    MarkdownParams,
    MarkdownTableSerializer,
)
from ingest.sec_tables import ExtractedTable, TableRow, extract_sec_tables

CHUNK_MAX_TOKENS = 512
DOWNLOADS_DIR = Path(__file__).resolve().parents[2] / "data" / "downloads"
MANIFEST_PATH = Path(__file__).resolve().parents[2] / "data" / "markdown" / "manifest.json"

_ITEM_SECTION_RE = re.compile(r"\bItem\s+[\dA-Z.]+\b", re.IGNORECASE)


class PatchedOpenAITokenizer(OpenAITokenizer):
    """Allow tiktoken special tokens that appear in SEC filing text."""

    def count_tokens(self, text: str) -> int:
        return len(
            self.tokenizer.encode(
                text=text,
                allowed_special=set(),
                disallowed_special=(),
            )
        )


class MarkdownTableSerializerProvider(ChunkingSerializerProvider):
    """Serialize tables as Markdown for 10-K financial tables."""

    def get_serializer(self, doc: Any) -> ChunkingDocSerializer:
        return ChunkingDocSerializer(
            doc=doc,
            table_serializer=MarkdownTableSerializer(),
            params=MarkdownParams(compact_tables=True),
        )


@dataclass(frozen=True, slots=True)
class ChunkRecord:
    chunk_index: int
    text: str
    page: str | None
    section: str | None
    token_count: int
    chunk_metadata: dict[str, Any]


def load_manifest_html_paths() -> dict[str, str]:
    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    paths: dict[str, str] = {}
    for filing in manifest.get("filings", []):
        accession = filing["accession_number"]
        html_path = filing.get("html_local_path")
        if not html_path:
            html_path = str(Path(filing["local_path"]).with_suffix(".htm"))
        paths[accession] = html_path
    return paths


def html_path_for_accession(accession_number: str) -> Path:
    paths = load_manifest_html_paths()
    if accession_number not in paths:
        raise KeyError(f"Accession {accession_number} not found in {MANIFEST_PATH}")
    html_path = DOWNLOADS_DIR / paths[accession_number]
    if not html_path.is_file():
        raise FileNotFoundError(f"Missing HTML file: {html_path}")
    return html_path


def build_tokenizer(max_tokens: int = CHUNK_MAX_TOKENS) -> PatchedOpenAITokenizer:
    return PatchedOpenAITokenizer(
        tokenizer=tiktoken.get_encoding("cl100k_base"),
        max_tokens=max_tokens,
    )


def build_hybrid_chunker(
    max_tokens: int = CHUNK_MAX_TOKENS,
) -> HybridChunker:
    return HybridChunker(
        tokenizer=build_tokenizer(max_tokens=max_tokens),
        merge_peers=True,
        repeat_table_header=True,
        serializer_provider=MarkdownTableSerializerProvider(),
    )


def build_hierarchical_chunker() -> HierarchicalChunker:
    return HierarchicalChunker(
        serializer_provider=MarkdownTableSerializerProvider(),
    )


def convert_html_to_document(html_path: Path) -> Any:
    return DocumentConverter().convert(html_path).document


def _page_from_chunk_meta(meta: Any) -> str | None:
    origin = getattr(meta, "origin", None)
    if origin is not None:
        page_no = getattr(origin, "page_no", None)
        if page_no is not None:
            return str(page_no)

    for item in getattr(meta, "doc_items", []):
        prov = getattr(item, "prov", None) or []
        for entry in prov:
            page_no = getattr(entry, "page_no", None)
            if page_no is not None:
                return str(page_no)
    return None


def _section_from_chunk(meta: Any, text: str) -> str | None:
    headings = getattr(meta, "headings", None) or []
    if headings:
        return " > ".join(headings)

    match = _ITEM_SECTION_RE.search(text)
    if match:
        return match.group(0)
    return None


def map_chunk_record(
    *,
    chunk_index: int,
    chunk: Any,
    chunker: HybridChunker,
    filing_metadata: dict[str, Any],
) -> ChunkRecord:
    contextualized = chunker.contextualize(chunk=chunk)
    meta = chunk.meta
    tokenizer = chunker.tokenizer

    return ChunkRecord(
        chunk_index=chunk_index,
        text=contextualized,
        page=_page_from_chunk_meta(meta),
        section=_section_from_chunk(meta, contextualized),
        token_count=tokenizer.count_tokens(contextualized),
        chunk_metadata={
            **_base_chunk_metadata(filing_metadata),
            "chunk_kind": "narrative",
            "raw_text": chunk.text,
            "docling_meta": meta.export_json_dict(),
        },
    )


def chunk_document(
    html_path: Path,
    filing_metadata: dict[str, Any],
    *,
    max_chunks: int | None = None,
) -> list[ChunkRecord]:
    html = html_path.read_text(encoding="utf-8")
    doc = convert_html_to_document(html_path)
    chunker = build_hybrid_chunker()
    tables = extract_sec_tables(html)
    used_table_indexes: set[int] = set()
    records: list[ChunkRecord] = []

    for index, chunk in enumerate(chunker.chunk(dl_doc=doc)):
        if max_chunks is not None and index >= max_chunks:
            break
        if _chunk_contains_table(chunk):
            table = _matching_table_for_chunk(
                chunker.contextualize(chunk=chunk),
                tables,
                used_table_indexes,
            )
            narrative_text = _narrative_text_without_tables(
                chunker.contextualize(chunk=chunk)
            )
            if narrative_text:
                records.append(
                    ChunkRecord(
                        chunk_index=len(records),
                        text=narrative_text,
                        page=_page_from_chunk_meta(chunk.meta),
                        section=_section_from_chunk(chunk.meta, narrative_text),
                        token_count=chunker.tokenizer.count_tokens(narrative_text),
                        chunk_metadata={
                            **_base_chunk_metadata(filing_metadata),
                            "chunk_kind": "narrative",
                            "raw_text": narrative_text,
                            "docling_meta": chunk.meta.export_json_dict(),
                        },
                    )
                )
            if table is not None:
                _append_table_row_records(
                    records=records,
                    table=table,
                    chunker=chunker,
                    filing_metadata=filing_metadata,
                )
                used_table_indexes.add(table.table_index)
                continue
            records.append(
                map_chunk_record(
                    chunk_index=len(records),
                    chunk=chunk,
                    chunker=chunker,
                    filing_metadata=filing_metadata,
                )
            )
            continue
        records.append(
            map_chunk_record(
                chunk_index=len(records),
                chunk=chunk,
                chunker=chunker,
                filing_metadata=filing_metadata,
            )
        )

    if max_chunks is None:
        for table in tables:
            if table.table_index in used_table_indexes:
                continue
            _append_table_row_records(
                records=records,
                table=table,
                chunker=chunker,
                filing_metadata=filing_metadata,
            )

    return records


def _append_table_row_records(
    *,
    records: list[ChunkRecord],
    table: ExtractedTable,
    chunker: HybridChunker,
    filing_metadata: dict[str, Any],
) -> None:
    for row in table.rows:
        text = _table_row_chunk_text(table, row)
        records.append(
            ChunkRecord(
                chunk_index=len(records),
                text=text,
                page=None,
                section=table.title,
                token_count=chunker.tokenizer.count_tokens(text),
                chunk_metadata={
                    **_base_chunk_metadata(filing_metadata),
                    "chunk_kind": "table_row",
                    "table_index": table.table_index,
                    "table_title": table.title,
                    "row_label": row.label,
                    "raw_text": text,
                    "table": table.to_dict(),
                },
            )
        )


def _base_chunk_metadata(filing_metadata: dict[str, Any]) -> dict[str, Any]:
    return {
        "ticker": filing_metadata.get("ticker"),
        "cik": filing_metadata.get("cik"),
        "company_name": filing_metadata.get("company_name"),
        "form": filing_metadata.get("form"),
        "filing_date": filing_metadata.get("filing_date"),
        "report_date": filing_metadata.get("report_date"),
        "fiscal_year": filing_metadata.get("fiscal_year"),
        "accession_number": filing_metadata.get("accession_number"),
        "primary_document": filing_metadata.get("primary_document"),
        "source_url": filing_metadata.get("source_url"),
    }


def _chunk_contains_table(chunk: Any) -> bool:
    for item in getattr(chunk.meta, "doc_items", []) or []:
        label = str(getattr(item, "label", "")).lower()
        if "table" in label:
            return True
    return False


def _matching_table_for_chunk(
    chunk_text: str,
    tables: list[ExtractedTable],
    used_table_indexes: set[int],
) -> ExtractedTable | None:
    for table in tables:
        if table.table_index in used_table_indexes:
            continue
        if _table_matches_chunk(chunk_text, table):
            return table
    return None


def _table_matches_chunk(chunk_text: str, table: ExtractedTable) -> bool:
    if not table.rows:
        return False
    first_row = table.rows[0]
    if first_row.label and first_row.label in chunk_text:
        return True
    return any(cell.text.strip("$") in chunk_text for cell in first_row.cells if cell.text)


def _narrative_text_without_tables(text: str) -> str:
    lines = []
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        if stripped.startswith("|"):
            continue
        lines.append(stripped)
    return "\n".join(lines)


def _table_row_chunk_text(table: ExtractedTable, row: TableRow) -> str:
    title = table.title or f"Table {table.table_index + 1}"
    lines = [title]
    if table.units:
        lines.append(f"Units: {table.units}")

    row_markdown = _markdown_for_row(table, row)
    lines.append(row_markdown)
    if table.footnotes:
        lines.extend(table.footnotes)
    return "\n".join(lines)


def _markdown_for_row(table: ExtractedTable, row: TableRow) -> str:
    header = "| " + " | ".join(column.label for column in table.columns) + " |"
    separator = "| " + " | ".join("---" for _ in table.columns) + " |"
    body = "| " + " | ".join([row.label, *[cell.text for cell in row.cells]]) + " |"
    return "\n".join([header, separator, body])


def chunk_document_hierarchical(html_path: Path) -> list[str]:
    """Layout-only chunks from HierarchicalChunker."""
    doc = convert_html_to_document(html_path)
    chunker = build_hierarchical_chunker()
    return [chunk.text for chunk in chunker.chunk(dl_doc=doc)]


def iter_all_html_paths() -> Iterator[tuple[str, Path]]:
    for accession, relative_path in load_manifest_html_paths().items():
        yield accession, DOWNLOADS_DIR / relative_path
INNER_EOF

# 2. Create backend/ingest/embeddings.py (local sentence-transformers/all-MiniLM-L6-v2)
cat << 'INNER_EOF' > backend/ingest/embeddings.py
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
INNER_EOF

# 3. Create backend/ingest/chunk_and_embed.py
cat << 'INNER_EOF' > backend/ingest/chunk_and_embed.py
"""Chunk SEC HTML filings, embed chunks locally, and store in document_chunks."""

from __future__ import annotations

import argparse
from dataclasses import dataclass

from sqlalchemy import create_engine, delete, func, select
from sqlalchemy.orm import Session

from app.config import settings
from app.database.models import DocumentChunk, MessageCitation, SourceDocument
from ingest.chunking import (
    CHUNK_MAX_TOKENS,
    ChunkRecord,
    chunk_document,
    html_path_for_accession,
    iter_all_html_paths,
)
from ingest.embeddings import EMBED_BATCH_SIZE, embed_texts


@dataclass(frozen=True, slots=True)
class IngestCounts:
    processed: int = 0
    skipped: int = 0
    chunks_written: int = 0


def _filing_metadata(document: SourceDocument) -> dict:
    return {
        "ticker": document.ticker,
        "cik": document.cik,
        "company_name": document.company_name,
        "form": document.form,
        "filing_date": document.filing_date.isoformat(),
        "report_date": document.report_date.isoformat() if document.report_date else None,
        "accession_number": document.accession_number,
        "primary_document": document.primary_document,
        "source_url": document.source_url,
    }


def _document_has_chunks(session: Session, document_id) -> bool:
    count = session.scalar(
        select(func.count())
        .select_from(DocumentChunk)
        .where(DocumentChunk.source_document_id == document_id)
    )
    return bool(count)


def _delete_chunks(session: Session, document_id) -> None:
    chunk_ids = select(DocumentChunk.id).where(DocumentChunk.source_document_id == document_id)
    session.execute(
        delete(MessageCitation).where(MessageCitation.chunk_id.in_(chunk_ids))
    )
    session.execute(
        delete(DocumentChunk).where(DocumentChunk.source_document_id == document_id)
    )


def ingest_document(
    session: Session,
    document: SourceDocument,
    *,
    max_chunks: int | None = None,
    dry_run: bool = False,
    skip_existing: bool = True,
    force: bool = False,
) -> int:
    if force and not dry_run:
        _delete_chunks(session, document.id)
    elif skip_existing and _document_has_chunks(session, document.id):
        print(f"Skipping existing chunks for {document.accession_number}")
        return 0

    html_path = html_path_for_accession(document.accession_number)
    print(f"Chunking {document.accession_number} from {html_path.name}...")
    records = chunk_document(
        html_path,
        _filing_metadata(document),
        max_chunks=max_chunks,
    )

    if not records:
        print(f"No chunks produced for {document.accession_number}")
        return 0

    max_tokens = max(record.token_count for record in records)
    print(
        f"  {len(records)} chunk(s), max_tokens={max_tokens}, "
        f"limit={CHUNK_MAX_TOKENS}"
    )

    if dry_run:
        sample = records[0]
        print(f"  sample section={sample.section!r} page={sample.page!r}")
        print(f"  sample preview={sample.text[:120]!r}")
        return len(records)

    texts = [record.text for record in records]
    print(f"  Embedding {len(texts)} chunk(s) (batch_size={EMBED_BATCH_SIZE})...")
    vectors = embed_texts(texts)

    for record, embedding in zip(records, vectors, strict=True):
        metadata = dict(record.chunk_metadata)
        # Store metadata attributes inside database model
        session.add(
            DocumentChunk(
                source_document_id=document.id,
                chunk_index=record.chunk_index,
                page=record.page,
                section=record.section,
                content=record.text,
                embedding=embedding,
                token_count=record.token_count,
                ticker=document.ticker,
                company_name=document.company_name,
                form=document.form,
                filing_date=document.filing_date.isoformat(),
                filing_year=document.filing_date.year,
                accession_number=document.accession_number,
                metadata_json=metadata,
            )
        )

    session.commit()
    print(f"  Wrote {len(records)} chunk(s) for {document.accession_number}")
    return len(records)


def ingest_accessions(
    accessions: list[str],
    *,
    max_chunks: int | None = None,
    dry_run: bool = False,
    skip_existing: bool = True,
    force: bool = False,
) -> IngestCounts:
    engine = create_engine(settings.database_url)
    counts = IngestCounts()

    with Session(engine) as session:
        for accession in accessions:
            document = session.scalar(
                select(SourceDocument).where(
                    SourceDocument.accession_number == accession
                )
            )
            if document is None:
                raise ValueError(
                    f"No source_document for accession {accession}. "
                    "Run `load_source_documents` first."
                )

            if (
                not dry_run
                and not force
                and skip_existing
                and _document_has_chunks(session, document.id)
            ):
                print(f"Skipping existing chunks for {accession}")
                counts = IngestCounts(
                    processed=counts.processed,
                    skipped=counts.skipped + 1,
                    chunks_written=counts.chunks_written,
                )
                continue

            written = ingest_document(
                session,
                document,
                max_chunks=max_chunks,
                dry_run=dry_run,
                skip_existing=skip_existing,
                force=force,
            )
            counts = IngestCounts(
                processed=counts.processed + 1,
                skipped=counts.skipped,
                chunks_written=counts.chunks_written + written,
            )

    return counts


def ingest_all(
    *,
    max_chunks: int | None = None,
    dry_run: bool = False,
    skip_existing: bool = True,
    force: bool = False,
) -> IngestCounts:
    accessions = [accession for accession, _ in iter_all_html_paths()]
    return ingest_accessions(
        accessions,
        max_chunks=max_chunks,
        dry_run=dry_run,
        skip_existing=skip_existing,
        force=force,
    )


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("--accession", help="Process one filing by accession number")
    target.add_argument("--all", action="store_true", help="Process all manifest filings")
    parser.add_argument(
        "--max-chunks",
        type=int,
        default=None,
        help="Cap chunks per document",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Chunk only; no embeddings or database writes",
    )
    parser.add_argument(
        "--skip-existing",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Skip documents that already have chunks",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Delete existing chunks before re-ingesting",
    )
    return parser


def main() -> None:
    parser = _build_parser()
    args = parser.parse_args()

    if args.all:
        result = ingest_all(
            max_chunks=args.max_chunks,
            dry_run=args.dry_run,
            skip_existing=args.skip_existing,
            force=args.force,
        )
    else:
        result = ingest_accessions(
            [args.accession],
            max_chunks=args.max_chunks,
            dry_run=args.dry_run,
            skip_existing=args.skip_existing,
            force=args.force,
        )

    print(
        "Done: "
        f"{result.processed} document(s) processed, "
        f"{result.skipped} skipped, "
        f"{result.chunks_written} chunk(s) written"
    )


if __name__ == "__main__":
    main()
INNER_EOF

echo "Backend Ingest Pipeline setup complete! Clean up script."
rm setup_backend_ingest.sh
EOF

# Run the setup script
bash setup_backend_ingest.sh