# Execute from your repository root
cat << 'EOF' > run_docling_conversion.sh
#!/bin/bash
set -e

# Create directories
mkdir -p backend/ingest
mkdir -p data/markdown

# 1. Create backend/ingest/sec_tables.py
cat << 'INNER_EOF' > backend/ingest/sec_tables.py
"""SEC HTML table extraction for financial filing tables."""

from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass, field
from html.parser import HTMLParser
from typing import Any

_AMOUNT_RE = re.compile(r"^\(?\$?[\d,]+(?:\.\d+)?\)?$")
_FOOTNOTE_RE = re.compile(r"^\(\d+\)")
_UNIT_RE = re.compile(r"\(([^)]*(?:million|thousand|billion)[^)]*)\)", re.IGNORECASE)
_VOID_TAGS = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param"}


@dataclass(frozen=True, slots=True)
class InlineFact:
    name: str | None
    context_ref: str | None
    unit_ref: str | None
    decimals: str | None
    scale: str | None
    fact_id: str | None
    value: str

    def to_dict(self) -> dict[str, str | None]:
        return {
            "name": self.name,
            "context_ref": self.context_ref,
            "unit_ref": self.unit_ref,
            "decimals": self.decimals,
            "scale": self.scale,
            "fact_id": self.fact_id,
            "value": self.value,
        }


@dataclass(frozen=True, slots=True)
class TableColumn:
    label: str

    def to_dict(self) -> dict[str, str]:
        return {"label": self.label}


@dataclass(frozen=True, slots=True)
class TableCell:
    text: str
    facts: tuple[InlineFact, ...] = ()

    def to_dict(self) -> dict[str, Any]:
        return {
            "text": self.text,
            "facts": [fact.to_dict() for fact in self.facts],
        }


@dataclass(frozen=True, slots=True)
class TableRow:
    label: str
    cells: tuple[TableCell, ...]

    def to_dict(self) -> dict[str, Any]:
        return {
            "label": self.label,
            "cells": [cell.to_dict() for cell in self.cells],
        }


@dataclass(frozen=True, slots=True)
class ExtractedTable:
    table_index: int
    title: str | None
    units: str | None
    columns: tuple[TableColumn, ...]
    rows: tuple[TableRow, ...]
    footnotes: list[str]
    markdown: str
    source_html_hash: str

    def to_dict(self) -> dict[str, Any]:
        return {
            "table_index": self.table_index,
            "title": self.title,
            "units": self.units,
            "columns": [column.to_dict() for column in self.columns],
            "rows": [row.to_dict() for row in self.rows],
            "footnotes": self.footnotes,
            "markdown": self.markdown,
            "source_html_hash": self.source_html_hash,
        }


@dataclass(slots=True)
class _Node:
    tag: str
    attrs: dict[str, str]
    children: list[_Node | str] = field(default_factory=list)
    parent: _Node | None = None


@dataclass(frozen=True, slots=True)
class _RawCell:
    text: str
    colspan: int
    facts: tuple[InlineFact, ...]


class _TreeParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.root = _Node(tag="document", attrs={})
        self._stack = [self.root]

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag == "br":
            self._stack[-1].children.append("\n")
            return

        node = _Node(
            tag=tag.lower(),
            attrs={key.lower(): value or "" for key, value in attrs},
            parent=self._stack[-1],
        )
        self._stack[-1].children.append(node)
        if tag.lower() not in _VOID_TAGS:
            self._stack.append(node)

    def handle_endtag(self, tag: str) -> None:
        normalized = tag.lower()
        for index in range(len(self._stack) - 1, 0, -1):
            if self._stack[index].tag == normalized:
                del self._stack[index:]
                return

    def handle_data(self, data: st