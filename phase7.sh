# Execute from your repository root
cat << 'EOF' > setup_frontend_phase7.sh
#!/bin/bash
set -e

# Ensure directories exist
mkdir -p frontend/src/lib
mkdir -p frontend/src/components/chat
mkdir -p frontend/src/pages/chat

# 1. Create frontend/src/lib/citations.ts
cat << 'INNER_EOF' > frontend/src/lib/citations.ts
import { isDataUIPart, type UIMessage } from 'ai'

export type CitationPayload = {
  citationIndex: number
  chunkId: string
  excerpt: string
  ticker: string
  companyName?: string
  form: string
  filingDate: string
  page?: string
  section?: string
}

export type PipelineStage =
  | 'analyzing'
  | 'searching'
  | 'reading'
  | 'verifying'
  | 'streaming'

export type PipelineStatus = {
  stage: PipelineStage
  message: string
}

function isCitationData(data: unknown): data is CitationPayload {
  if (typeof data !== 'object' || data === null) {
    return false
  }
  const record = data as Record<string, unknown>
  return (
    typeof record.citationIndex === 'number' &&
    typeof record.chunkId === 'string' &&
    typeof record.excerpt === 'string' &&
    typeof record.ticker === 'string' &&
    typeof record.form === 'string' &&
    typeof record.filingDate === 'string'
  )
}

export function isCitationPart(
  part: UIMessage['parts'][number],
): part is UIMessage['parts'][number] & { type: 'data-citation'; data: CitationPayload } {
  return isDataUIPart(part) && part.type === 'data-citation' && isCitationData(part.data)
}

export function isStatusPart(
  part: unknown,
): part is { type: 'data-status'; data: PipelineStatus } {
  if (typeof part !== 'object' || part === null) {
    return false
  }
  const record = part as Record<string, unknown>
  if (record.type !== 'data-status' || typeof record.data !== 'object' || record.data === null) {
    return false
  }
  const data = record.data as Record<string, unknown>
  return typeof data.stage === 'string' && typeof data.message === 'string'
}

export function citationsFromMessage(message: UIMessage): CitationPayload[] {
  return message.parts
    .filter(isCitationPart)
    .map((part) => part.data)
    .sort((a, b) => a.citationIndex - b.citationIndex)
}

export function textFromMessage(message: UIMessage): string {
  return message.parts
    .filter((part) => part.type === 'text')
    .map((part) => part.text)
    .join('')
}

export function citationLabel(citation: CitationPayload): string {
  const parts = [citation.ticker, citation.form, citation.filingDate]
  if (citation.page) {
    parts.push(`p.${citation.page}`)
  }
  return parts.join(' · ')
}

export function citationHeader(citation: CitationPayload): string {
  const company = citation.companyName ?? citation.ticker
  return `${company} · ${citation.form} · filed ${citation.filingDate}`
}

export function citationSubtitle(citation: CitationPayload): string | null {
  const parts: string[] = []
  if (citation.page) {
    parts.push(`Page ${citation.page}`)
  }
  if (citation.section) {
    parts.push(citation.section)
  }
  return parts.length > 0 ? parts.join(' · ') : null
}

export function citationByIndex(
  citations: CitationPayload[],
  index: number,
): CitationPayload | undefined {
  return citations.find((citation) => citation.citationIndex === index)
}
INNER_EOF

# 2. Create frontend/src/lib/chat-errors.ts
cat << 'INNER_EOF' > frontend/src/lib/chat-errors.ts
import { ApiError } from '@/lib/http'

export type ChatErrorKind =
  | 'network'
  | 'auth'
  | 'grounding'
  | 'retrieval'
  | 'generic'

export type ClassifiedChatError = {
  kind: ChatErrorKind
  title: string
  message: string
  showLoginLink: boolean
}

function messageIncludesAny(text: string, needles: string[]): boolean {
  const lower = text.toLowerCase()
  return needles.some((needle) => lower.includes(needle.toLowerCase()))
}

export function classifyChatError(error: Error): ClassifiedChatError {
  if (error instanceof ApiError) {
    if (error.isNetworkError) {
      return {
        kind: 'network',
        title: 'Connection problem',
        message:
          "Can't reach the server. Check your connection and that the backend is running.",
        showLoginLink: false,
      }
    }

    if (error.status === 401) {
      return {
        kind: 'auth',
        title: 'Session expired',
        message: 'Your sign-in session has expired. Please sign in again.',
        showLoginLink: true,
      }
    }

    if (error.status === 403) {
      return {
        kind: 'auth',
        title: 'Access denied',
        message: 'You do not have access to this conversation.',
        showLoginLink: false,
      }
    }
  }

  const text = error.message || ''

  if (
    messageIncludesAny(text, [
      'grounding',
      'citation',
      'verified against source',
      'source passages',
      'fully verify',
    ])
  ) {
    return {
      kind: 'grounding',
      title: 'Answer not verified',
      message:
        text ||
        'The answer could not be verified against source documents. Try rephrasing your question.',
      showLoginLink: false,
    }
  }

  if (messageIncludesAny(text, ['assistant run failed', 'retrieval', 'search'])) {
    return {
      kind: 'retrieval',
      title: 'Search failed',
      message: 'Search or analysis failed. Please try again.',
      showLoginLink: false,
    }
  }

  if (messageIncludesAny(text, ['failed to fetch', 'network', 'cors'])) {
    return {
      kind: 'network',
      title: 'Connection problem',
      message:
        "Can't reach the server. Check your connection and that the backend is running.",
      showLoginLink: false,
    }
  }

  return {
    kind: 'generic',
    title: 'Something went wrong',
    message: text || 'Something went wrong while sending your message.',
    showLoginLink: false,
  }
}
INNER_EOF

# 3. Create frontend/src/components/chat/PipelineStatus.tsx
cat << 'INNER_EOF' > frontend/src/components/chat/PipelineStatus.tsx
import { type PipelineStatus as PipelineStatusState } from '@/lib/citations'

type PipelineStatusProps = {
  isSubmitted: boolean
  pipelineStatus: PipelineStatusState | null
}

export function PipelineStatus({ isSubmitted, pipelineStatus }: PipelineStatusProps) {
  const message =
    isSubmitted && !pipelineStatus
      ? 'Analyzing your question…'
      : (pipelineStatus?.message ?? 'Researching filings…')

  return (
    <p
      aria-live="polite"
      className="w-fit bg-clip-text text-sm font-medium text-transparent bg-[linear-gradient(to_right,var(--muted-foreground)_35%,var(--foreground)_50%,var(--muted-foreground)_65%)] bg-size-[200%_auto] animate-[shimmer_2.5s_linear_infinite]"
    >
      {message}
    </p>
  )
}
INNER_EOF

# 4. Create frontend/src/components/chat/CitationMarker.tsx
cat << 'INNER_EOF' > frontend/src/components/chat/CitationMarker.tsx
import { cn } from '@/lib/utils'

type CitationMarkerProps = {
  index: number
  selected?: boolean
  onSelect: (index: number) => void
}

export function CitationMarker({ index, selected, onSelect }: CitationMarkerProps) {
  return (
    <button
      type="button"
      onClick={() => onSelect(index)}
      aria-label={`Show source ${index}`}
      className={cn(
        'mx-0.5 inline-flex h-4 min-w-4 -translate-y-1 items-center justify-center rounded px-1 align-baseline text-[0.65rem] font-semibold tabular-nums no-underline transition-colors',
        selected
          ? 'bg-primary text-primary-foreground'
          : 'bg-muted text-muted-foreground hover:bg-foreground hover:text-background',
      )}
    >
      {index}
    </button>
  )
}
INNER_EOF

# 5. Create frontend/src/components/chat/CitationChip.tsx
cat << 'INNER_EOF' > frontend/src/components/chat/CitationChip.tsx
import { citationLabel, type CitationPayload } from '@/lib/citations'
import { cn } from '@/lib/utils'

type CitationChipProps = {
  citation: CitationPayload
  selected?: boolean
  onSelect: (citation: CitationPayload) => void
}

export function CitationChip({ citation, selected, onSelect }: CitationChipProps) {
  return (
    <button
      type="button"
      onClick={() => onSelect(citation)}
      className={cn(
        'inline-flex max-w-full items-center gap-1.5 rounded-full border py-1 pr-3 pl-1 text-left text-xs transition-colors',
        selected
          ? 'border-foreground bg-foreground/5 text-foreground'
          : 'border-border bg-background text-muted-foreground hover:border-foreground/40 hover:text-foreground',
      )}
    >
      <span className="flex size-4 shrink-0 items-center justify-center rounded-full bg-foreground text-[0.6rem] font-semibold text-background tabular-nums">
        {citation.citationIndex}
      </span>
      <span className="truncate font-medium">{citationLabel(citation)}</span>
    </button>
  )
}
INNER_EOF

# 6. Create frontend/src/components/chat/AssistantMarkdown.tsx
cat << 'INNER_EOF' > frontend/src/components/chat/AssistantMarkdown.tsx
import { useMemo } from 'react'
import ReactMarkdown, { type Components } from 'react-markdown'
import remarkGfm from 'remark-gfm'
import remarkBreaks from 'remark-breaks'

import { CitationMarker } from '@/components/chat/CitationMarker'
import { citationByIndex, type CitationPayload } from '@/lib/citations'
import { cn } from '@/lib/utils'

const CITE_PREFIX = '#citation-'

const MARKDOWN_CLASSES = cn(
  'space-y-3 text-sm leading-relaxed text-foreground',
  '[&_p]:leading-relaxed [&_strong]:font-semibold',
  '[&_a]:font-medium [&_a]:underline [&_a]:underline-offset-4',
  '[&_ul]:list-disc [&_ul]:pl-5 [&_ol]:list-decimal [&_ol]:pl-5 [&_li]:my-1',
  '[&_h1]:text-base [&_h1]:font-semibold [&_h2]:text-base [&_h2]:font-semibold [&_h3]:text-sm [&_h3]:font-semibold',
  '[&_table]:w-full [&_table]:text-left [&_th]:border-b [&_th]:py-1.5 [&_th]:pr-3 [&_th]:font-semibold [&_td]:border-b [&_td]:py-1.5 [&_td]:pr-3 [&_td]:align-top',
  '[&_blockquote]:border-l-2 [&_blockquote]:border-border [&_blockquote]:pl-3 [&_blockquote]:text-muted-foreground',
)

function withCitationLinks(text: string, validIndices: Set<number>): string {
  return text.replace(/\[(\d+)\]/g, (match, digits: string) => {
    const index = Number(digits)
    return validIndices.has(index) ? `[${match}](${CITE_PREFIX}${index})` : match
  })
}

type AssistantMarkdownProps = {
  text: string
  citations: CitationPayload[]
  selectedCitationIndex: number | null
  onSelectCitation: (citation: CitationPayload) => void
}

export function AssistantMarkdown({
  text,
  citations,
  selectedCitationIndex,
  onSelectCitation,
}: AssistantMarkdownProps) {
  const validIndices = useMemo(
    () => new Set(citations.map((citation) => citation.citationIndex)),
    [citations],
  )
  const source = useMemo(() => withCitationLinks(text, validIndices), [text, validIndices])

  const components: Partial<Components> = useMemo(
    () => ({
      a({ href, children, ...props }) {
        if (href?.startsWith(CITE_PREFIX)) {
          const index = Number(href.slice(CITE_PREFIX.length))
          const citation = citationByIndex(citations, index)
          if (citation) {
            return (
              <CitationMarker
                index={index}
                selected={selectedCitationIndex === index}
                onSelect={() => onSelectCitation(citation)}
              />
            )
          }
        }
        return (
          <a href={href} target="_blank" rel="noopener noreferrer" {...props}>
            {children}
          </a>
        )
      },
    }),
    [citations, selectedCitationIndex, onSelectCitation],
  )

  return (
    <div className={MARKDOWN_CLASSES}>
      <ReactMarkdown
        remarkPlugins={[remarkGfm, remarkBreaks]}
        components={components}
      >
        {source}
      </ReactMarkdown>
    </div>
  )
}
INNER_EOF

# 7. Create frontend/src/components/chat/AssistantMessage.tsx
cat << 'INNER_EOF' > frontend/src/components/chat/AssistantMessage.tsx
import { useState } from 'react'
import type { UIMessage } from 'ai'
import { Check, Copy } from 'lucide-react'

import { AssistantMarkdown } from '@/components/chat/AssistantMarkdown'
import { CitationChip } from '@/components/chat/CitationChip'
import { Button } from '@/components/ui/button'
import {
  citationsFromMessage,
  textFromMessage,
  type CitationPayload,
} from '@/lib/citations'

type AssistantMessageProps = {
  message: UIMessage
  selectedCitationIndex: number | null
  onSelectCitation: (citation: CitationPayload) => void
  isStreaming?: boolean
}

function CopyButton({ text }: { text: string }) {
  const [copied, setCopied] = useState(false)

  async function handleCopy() {
    await navigator.clipboard.writeText(text)
    setCopied(true)
    setTimeout(() => setCopied(false), 1500)
  }

  return (
    <Button
      type="button"
      variant="ghost"
      size="icon"
      className="h-7 w-7 text-muted-foreground"
      onClick={() => void handleCopy()}
      aria-label="Copy answer"
    >
      {copied ? <Check className="size-3.5" /> : <Copy className="size-3.5" />}
    </Button>
  )
}

export function AssistantMessage({
  message,
  selectedCitationIndex,
  onSelectCitation,
  isStreaming = false,
}: AssistantMessageProps) {
  const text = textFromMessage(message)
  const citations = citationsFromMessage(message)
  const hasNoEvidence = !isStreaming && text.length > 0 && citations.length === 0

  return (
    <div className="min-w-0 space-y-3">
      {text ? (
        <AssistantMarkdown
          text={text}
          citations={citations}
          selectedCitationIndex={selectedCitationIndex}
          onSelectCitation={onSelectCitation}
        />
      ) : null}

      {isStreaming && text ? (
        <span className="inline-block h-4 w-2 translate-y-0.5 animate-pulse rounded-sm bg-foreground" />
      ) : null}

      {hasNoEvidence ? (
        <p className="rounded-lg border border-dashed bg-muted/40 px-3 py-2 text-xs text-muted-foreground">
          No filing evidence was found to support this answer.
        </p>
      ) : null}

      {citations.length > 0 ? (
        <div className="flex flex-wrap gap-1.5 pt-1">
          {citations.map((citation) => (
            <CitationChip
              key={`${citation.chunkId}-${citation.citationIndex}`}
              citation={citation}
              selected={selectedCitationIndex === citation.citationIndex}
              onSelect={onSelectCitation}
            />
          ))}
        </div>
      ) : null}

      {!isStreaming && text ? (
        <div className="flex items-center gap-1 pt-0.5">
          <CopyButton text={text} />
        </div>
      ) : null}
    </div>
  )
}
INNER_EOF

# 8. Create frontend/src/components/chat/SourcePassageSheet.tsx
cat << 'INNER_EOF' > frontend/src/components/chat/SourcePassageSheet.tsx
import { useEffect, useMemo, useState } from 'react'
import ReactMarkdown from 'react-markdown'
import remarkGfm from 'remark-gfm'
import remarkBreaks from 'remark-breaks'

import { Badge } from '@/components/ui/badge'
import { Loader } from '@/components/ui/loader'
import {
  Sheet,
  SheetContent,
  SheetDescription,
  SheetHeader,
  SheetTitle,
} from '@/components/ui/sheet'
import {
  getCitationContext,
  type CitationContext,
  type CitationContextChunk,
  type CitationContextTable,
} from '@/lib/chat'
import { type CitationPayload } from '@/lib/citations'
import { cn } from '@/lib/utils'

const SOURCE_MARKDOWN_CLASSES = cn(
  'space-y-2 text-xs leading-relaxed text-foreground',
  '[&_p]:leading-relaxed',
  '[&_a]:font-medium [&_a]:underline [&_a]:underline-offset-4',
  '[&_ul]:list-disc [&_ul]:pl-4 [&_ol]:list-decimal [&_ol]:pl-4 [&_li]:my-1',
  '[&_table]:w-full [&_table]:min-w-max [&_table]:border-collapse [&_table]:text-left',
  '[&_th]:border [&_th]:bg-muted [&_th]:px-2 [&_th]:py-1.5 [&_th]:font-semibold',
  '[&_td]:border [&_td]:px-2 [&_td]:py-1.5 [&_td]:align-top',
  '[&_blockquote]:border-l-2 [&_blockquote]:border-border [&_blockquote]:pl-3 [&_blockquote]:text-muted-foreground',
)

const CHUNK_LABELS: Record<CitationContextChunk['role'], string> = {
  previous: 'Previous context',
  anchor: 'Cited passage',
  next: 'Next context',
}

function pipeTableCells(line: string): string[] {
  const trimmed = line.trim()
  if (!trimmed.startsWith('|')) {
    return []
  }
  return trimmed
    .replace(/^\|/, '')
    .replace(/\|$/, '')
    .split('|')
    .map((cell) => cell.trim())
}

function isPipeTableRow(line: string): boolean {
  return pipeTableCells(line).length > 1
}

function isSeparatorRow(line: string): boolean {
  const cells = pipeTableCells(line)
  return cells.length > 1 && cells.every((cell) => /^:?-{3,}:?$/.test(cell))
}

function separatorFor(row: string): string {
  const cells = pipeTableCells(row)
  return `| ${cells.map(() => '---').join(' | ')} |`
}

function normalizeMarkdownTables(text: string): string {
  const lines = text.split('\n')
  const output: string[] = []

  for (let index = 0; index < lines.length; ) {
    if (!isPipeTableRow(lines[index])) {
      output.push(lines[index])
      index += 1
      continue
    }

    const tableLines: string[] = []
    while (index < lines.length && isPipeTableRow(lines[index])) {
      tableLines.push(lines[index])
      index += 1
    }

    if (tableLines.length > 1 && !isSeparatorRow(tableLines[1])) {
      output.push(tableLines[0], separatorFor(tableLines[0]), ...tableLines.slice(1))
    } else {
      output.push(...tableLines)
    }
  }

  return output.join('\n')
}

function fallbackContext(citation: CitationPayload): CitationContext {
  return {
    anchorChunkId: citation.chunkId,
    documentId: '',
    ticker: citation.ticker,
    companyName: citation.companyName,
    form: citation.form,
    filingDate: citation.filingDate,
    sourceUrl: '',
    chunks: [
      {
        chunkId: citation.chunkId,
        chunkIndex: 0,
        role: 'anchor',
        text: citation.excerpt,
        page: citation.page,
        section: citation.section,
      },
    ],
  }
}

function SourceChunkCard({ chunk }: { chunk: CitationContextChunk }) {
  const isAnchor = chunk.role === 'anchor'
  const markdown = useMemo(() => normalizeMarkdownTables(chunk.text), [chunk.text])

  return (
    <section
      className={cn(
        'rounded-xl border p-3 shadow-xs',
        isAnchor ? 'border-primary/40 bg-primary/5' : 'border-border bg-muted/20',
      )}
    >
      <div className="mb-2 flex flex-wrap items-center gap-1.5">
        <span
          className={cn(
            'rounded-md px-2 py-1 text-[0.65rem] font-semibold tracking-wide uppercase',
            isAnchor ? 'bg-primary text-primary-foreground' : 'bg-background text-muted-foreground',
          )}
        >
          {CHUNK_LABELS[chunk.role]}
        </span>
        <Badge variant="outline">Chunk {chunk.chunkIndex}</Badge>
        {chunk.page ? <Badge variant="outline">Page {chunk.page}</Badge> : null}
        {chunk.section ? <Badge variant="outline">{chunk.section}</Badge> : null}
      </div>
      <div className="overflow-x-auto">
        <div className={SOURCE_MARKDOWN_CLASSES}>
          <ReactMarkdown remarkPlugins={[remarkGfm, remarkBreaks]}>
            {markdown}
          </ReactMarkdown>
        </div>
      </div>
    </section>
  )
}

function SourceTableCard({ table }: { table: CitationContextTable }) {
  const markdown = useMemo(() => normalizeMarkdownTables(table.markdown), [table.markdown])

  return (
    <section className="rounded-xl border border-primary/40 bg-primary/5 p-3 shadow-xs">
      <div className="mb-2 flex flex-wrap items-center gap-1.5">
        <span className="rounded-md bg-primary px-2 py-1 text-[0.65rem] font-semibold tracking-wide text-primary-foreground uppercase">
          Normalized table
        </span>
        <Badge variant="outline">Table {table.tableIndex}</Badge>
        {table.title ? <Badge variant="outline">{table.title}</Badge> : null}
        {table.units ? <Badge variant="outline">{table.units}</Badge> : null}
      </div>
      <div className="overflow-x-auto">
        <div className={SOURCE_MARKDOWN_CLASSES}>
          <ReactMarkdown remarkPlugins={[remarkGfm, remarkBreaks]}>
            {markdown}
          </ReactMarkdown>
        </div>
      </div>
    </section>
  )
}

type SourcePassageSheetProps = {
  citation: CitationPayload | null
  onOpenChange: (open: boolean) => void
}

export function SourcePassageSheet({ citation, onOpenChange }: SourcePassageSheetProps) {
  const [context, setContext] = useState<CitationContext | null>(null)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    if (!citation) {
      return
    }

    const activeCitation = citation
    let mounted = true

    async function load() {
      setContext(null)
      setLoading(true)
      setError(null)

      try {
        const nextContext = await getCitationContext(activeCitation.chunkId)
        if (mounted) {
          setContext(nextContext)
        }
      } catch {
        if (mounted) {
          setContext(fallbackContext(activeCitation))
          setError('Could not load neighboring chunks. Showing the saved excerpt.')
        }
      } finally {
        if (mounted) {
          setLoading(false)
        }
      }
    }

    void load()

    return () => {
      mounted = false
    }
  }, [citation])

  const activeContext =
    citation && context?.anchorChunkId === citation.chunkId ? context : null
  const resolvedContext = activeContext ?? (citation ? fallbackContext(citation) : null)
  const activeError = activeContext ? error : null

  return (
    <Sheet open={citation !== null} onOpenChange={onOpenChange}>
      <SheetContent side="right" className="flex w-full flex-col gap-0 sm:max-w-xl lg:max-w-2xl overflow-y-auto">
        {citation ? (
          <>
            <SheetHeader className="border-b pb-4">
              <div className="flex items-center gap-2">
                <span className="flex h-6 w-6 shrink-0 items-center justify-center rounded-md bg-foreground text-xs font-semibold text-background tabular-nums">
                  {citation.citationIndex}
                </span>
                <SheetTitle className="text-base text-left">
                  {citation.companyName ?? citation.ticker}
                </SheetTitle>
              </div>
              <SheetDescription className="sr-only">
                Source passage for citation {citation.citationIndex}
              </SheetDescription>
              <div className="flex flex-wrap gap-1.5 pt-1">
                <Badge variant="secondary">{citation.ticker}</Badge>
                <Badge variant="outline">{citation.form}</Badge>
                <Badge variant="outline">Filed {citation.filingDate}</Badge>
                {citation.page ? <Badge variant="outline">Page {citation.page}</Badge> : null}
                {citation.section ? (
                  <Badge variant="outline">{citation.section}</Badge>
                ) : null}
              </div>
            </SheetHeader>

            <div className="flex-1 space-y-3 pt-4">
              <div>
                <p className="text-xs font-medium tracking-wide text-muted-foreground uppercase">
                  Source context
                </p>
                <p className="mt-1 text-xs text-muted-foreground">
                  Neighboring chunks are shown around the cited passage for continuity.
                </p>
              </div>

              {loading ? (
                <div className="rounded-xl border border-dashed bg-muted/30 p-4">
                  <span className="text-xs text-muted-foreground animate-pulse">Loading source context...</span>
                </div>
              ) : null}

              {activeError ? (
                <p
                  className="rounded-lg border border-dashed bg-muted/40 px-3 py-2 text-xs text-muted-foreground"
                  role="alert"
                >
                  {activeError}
                </p>
              ) : null}

              {!loading && resolvedContext?.table ? (
                <SourceTableCard table={resolvedContext.table} />
              ) : null}

              {!loading &&
                resolvedContext?.chunks.map((chunk) => (
                  <SourceChunkCard key={chunk.chunkId} chunk={chunk} />
                ))}
            </div>
          </>
        ) : null}
      </SheetContent>
    </Sheet>
  )
}
INNER_EOF

# 9. Create frontend/src/components/chat/ChatError.tsx
cat << 'INNER_EOF' > frontend/src/components/chat/ChatError.tsx
import { Link } from 'react-router-dom'
import { AlertCircle } from 'lucide-react'

import { classifyChatError } from '@/lib/chat-errors'

type ChatErrorProps = {
  error: Error
}

export function ChatError({ error }: ChatErrorProps) {
  const classified = classifyChatError(error)

  return (
    <div className="rounded-lg border border-destructive bg-destructive/10 p-3 text-destructive">
      <div className="flex gap-2">
        <AlertCircle className="h-5 w-5 shrink-0" />
        <div className="space-y-1">
          <p className="font-semibold leading-none">{classified.title}</p>
          <p className="text-sm text-destructive/90">{classified.message}</p>
          {classified.showLoginLink ? (
            <Link to="/login" className="mt-1 inline-block font-medium underline underline-offset-4">
              Sign in again
            </Link>
          ) : null}
        </div>
      </div>
    </div>
  )
}
INNER_EOF

# 10. Create frontend/src/components/chat/MessageBubble.tsx
cat << 'INNER_EOF' > frontend/src/components/chat/MessageBubble.tsx
import type { UIMessage } from 'ai'

import { AssistantMessage } from '@/components/chat/AssistantMessage'
import { textFromMessage, type CitationPayload } from '@/lib/citations'

type MessageBubbleProps = {
  message: UIMessage
  selectedCitationIndex: number | null
  onSelectCitation: (citation: CitationPayload) => void
  isStreaming?: boolean
}

export function MessageBubble({
  message,
  selectedCitationIndex,
  onSelectCitation,
  isStreaming,
}: MessageBubbleProps) {
  if (message.role === 'assistant') {
    return (
      <AssistantMessage
        message={message}
        selectedCitationIndex={selectedCitationIndex}
        onSelectCitation={onSelectCitation}
        isStreaming={isStreaming}
      />
    )
  }

  const text = textFromMessage(message)

  return (
    <div className="flex justify-end">
      <div className="max-w-[80%] rounded-2xl rounded-br-md bg-secondary px-4 py-2.5 text-sm leading-relaxed whitespace-pre-wrap text-secondary-foreground">
        {text}
      </div>
    </div>
  )
}
INNER_EOF

# 11. Create frontend/src/components/chat/MessageList.tsx
cat << 'INNER_EOF' > frontend/src/components/chat/MessageList.tsx
import type { ChatStatus, UIMessage } from 'ai'
import { StickToBottom } from 'use-stick-to-bottom'
import { ChevronDown } from 'lucide-react'

import { MessageBubble } from '@/components/chat/MessageBubble'
import { PipelineStatus } from '@/components/chat/PipelineStatus'
import { Button } from '@/components/ui/button'
import { textFromMessage, type CitationPayload, type PipelineStatus as PipelineStatusState } from '@/lib/citations'

type MessageListProps = {
  messages: UIMessage[]
  status: ChatStatus
  pipelineStatus: PipelineStatusState | null
  selectedCitationIndex: number | null
  onSelectCitation: (citation: CitationPayload) => void
  onSendSuggestion: (text: string) => void
}

const EXAMPLE_QUESTIONS = [
  "Across Apple's 2021–2025 10-Ks, how did the revenue mix between iPhone, Services, Mac, and iPad change?",
  "For Amazon, compare AWS operating income and margin against North America and International from 2021–2025.",
  "How did NVIDIA describe demand drivers, customer concentration, and supply constraints for its Data Center business?",
  "Across Microsoft filings, what changed in how the company describes Azure, AI infrastructure, and cloud capacity constraints?",
] as const

export function MessageList({
  messages,
  status,
  pipelineStatus,
  selectedCitationIndex,
  onSelectCitation,
  onSendSuggestion,
}: MessageListProps) {
  const isBusy = status === 'submitted' || status === 'streaming'
  const lastMessage = messages[messages.length - 1]
  const lastIsStreamingAssistant =
    status === 'streaming' &&
    lastMessage?.role === 'assistant' &&
    textFromMessage(lastMessage).length > 0

  const showPipeline = isBusy && !lastIsStreamingAssistant

  return (
    <div className="relative flex-1 min-h-0 flex flex-col">
      <StickToBottom className="flex-1 overflow-y-auto" initial="instant">
        <StickToBottom.Content className="mx-auto w-full max-w-3xl gap-6 px-4 py-6 flex flex-col">
          {messages.length === 0 ? (
            <div className="flex flex-1 flex-col items-center justify-center gap-6 py-12 text-center">
              <div className="space-y-1">
                <h2 className="text-lg font-semibold text-foreground">
                  Ask about SEC filings
                </h2>
                <p className="text-sm text-muted-foreground">
                  Every answer is grounded in source documents with citations.
                </p>
              </div>
              <div className="flex flex-wrap justify-center gap-2 max-w-lg">
                {EXAMPLE_QUESTIONS.map((question) => (
                  <button
                    key={question}
                    type="button"
                    onClick={() => onSendSuggestion(question)}
                    className="rounded-xl border border-border bg-background p-3 text-left text-xs transition-colors hover:bg-muted text-muted-foreground leading-normal"
                  >
                    {question}
                  </button>
                ))}
              </div>
            </div>
          ) : null}

          {messages.map((message) => (
            <MessageBubble
              key={message.id}
              message={message}
              selectedCitationIndex={selectedCitationIndex}
              onSelectCitation={onSelectCitation}
              isStreaming={message === lastMessage && lastIsStreamingAssistant}
            />
          ))}

          {showPipeline ? (
            <PipelineStatus
              isSubmitted={status === 'submitted'}
              pipelineStatus={pipelineStatus}
            />
          ) : null}
        </StickToBottom.Content>
      </StickToBottom>
    </div>
  )
}
INNER_EOF

# 12. Create frontend/src/components/chat/ChatInput.tsx (real standard layout with send/stop triggers)
cat << 'INNER_EOF' > frontend/src/components/chat/ChatInput.tsx
import { useState } from 'react'
import type { ChatStatus } from 'ai'
import { ArrowUp, Square } from 'lucide-react'
import { Button } from '@/components/ui/button'

type ChatInputProps = {
  status: ChatStatus
  onSend: (text: string) => void
  onStop: () => void
}

export function ChatInput({ status, onSend, onStop }: ChatInputProps) {
  const [input, setInput] = useState('')
  const isBusy = status === 'submitted' || status === 'streaming'

  function submit() {
    const text = input.trim()
    if (!text || isBusy) return
    onSend(text)
    setInput('')
  }

  const handleKeyDown = (e: React.KeyboardEvent<HTMLTextAreaElement>) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault()
      submit()
    }
  }

  return (
    <div className="bg-background px-4 pb-4">
      <div className="mx-auto w-full max-w-3xl flex items-end gap-2 border border-input rounded-xl p-2 bg-background shadow-xs">
        <textarea
          rows={1}
          value={input}
          onChange={(e) => setInput(e.target.value)}
          onKeyDown={handleKeyDown}
          placeholder="Ask about SEC filings…"
          className="flex-1 max-h-48 min-h-[2.25rem] resize-none bg-transparent py-2 px-3 outline-none text-sm leading-relaxed"
          disabled={isBusy}
        />
        {isBusy ? (
          <Button type="button" size="icon" className="rounded-full shrink-0" onClick={onStop}>
            <Square className="size-4 fill-current" />
          </Button>
        ) : (
          <Button
            type="button"
            size="icon"
            className="rounded-full shrink-0"
            onClick={submit}
            disabled={input.trim() === ''}
            aria-label="Send message"
          >
            <ArrowUp className="size-4" />
          </Button>
        )}
      </div>
      <p className="mt-2 text-center text-xs text-muted-foreground">
        Answers are grounded in SEC filings. Verify citations before relying on them.
      </p>
    </div>
  )
}
INNER_EOF

# 13. Create frontend/src/components/chat/UserMenu.tsx
cat << 'INNER_EOF' > frontend/src/components/chat/UserMenu.tsx
import { useNavigate } from 'react-router-dom'
import { ChevronsUpDown, LogOut } from 'lucide-react'
import { Avatar, AvatarFallback } from '@/components/ui/avatar'
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu'
import { useSession } from '@/hooks/useSession'
import { supabase } from '@/lib/supabase'

export function UserMenu() {
  const navigate = useNavigate()
  const session = useSession()
  const email = session?.user?.email ?? 'Account'

  async function handleSignOut() {
    await supabase.auth.signOut()
    navigate('/login', { replace: true })
  }

  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <button className="flex w-full items-center gap-2 rounded-md p-2 text-left text-sm hover:bg-sidebar-accent hover:text-sidebar-accent-foreground outline-none">
          <Avatar className="h-6 w-6">
            <AvatarFallback className="text-[10px] bg-foreground text-background">
              {email.slice(0, 2).toUpperCase()}
            </AvatarFallback>
          </Avatar>
          <span className="truncate flex-1 font-medium text-left">{email}</span>
          <ChevronsUpDown className="h-4 w-4 text-muted-foreground shrink-0" />
        </button>
      </DropdownMenuTrigger>
      <DropdownMenuContent className="w-56" align="end">
        <DropdownMenuLabel className="truncate font-normal text-muted-foreground">
          {email}
        </DropdownMenuLabel>
        <DropdownMenuSeparator />
        <DropdownMenuItem onClick={() => void handleSignOut()}>
          <LogOut className="mr-2 h-4 w-4" />
          Sign out
        </DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  )
}
INNER_EOF

# 14. Create frontend/src/components/chat/ThreadSidebar.tsx
cat << 'INNER_EOF' > frontend/src/components/chat/ThreadSidebar.tsx
import { useState } from 'react'
import { Link, useNavigate, useParams } from 'react-router-dom'
import { Plus, Trash2 } from 'lucide-react'
import { toast } from 'sonner'
import { Logo } from '@/components/Logo'
import { UserMenu } from '@/components/chat/UserMenu'
import { Button } from '@/components/ui/button'
import {
  Sidebar,
  SidebarContent,
  SidebarFooter,
  SidebarGroup,
  SidebarGroupContent,
  SidebarGroupLabel,
  SidebarHeader,
  SidebarMenu,
  SidebarMenuAction,
  SidebarMenuButton,
  SidebarMenuItem,
  useSidebar,
} from '@/components/ui/sidebar'
import { useThreads } from '@/hooks/useThreads'
import { groupByRecency } from '@/lib/format'

export function ThreadSidebar() {
  const navigate = useNavigate()
  const { threadId } = useParams()
  const { setOpenMobile, isMobile } = useSidebar()
  const { threads, isLoading, createNewThread, deleteThread } = useThreads()
  const [isCreating, setIsCreating] = useState(false)

  const groups = groupByRecency(threads, (thread) => thread.updatedAt)

  async function handleNewChat() {
    setIsCreating(true)
    try {
      const id = await createNewThread()
      navigate(`/chats/${id}`)
      if (isMobile) setOpenMobile(false)
    } finally {
      setIsCreating(false)
    }
  }

  async function handleDeleteThread(id: string) {
    try {
      await deleteThread(id)
      toast.success('Conversation deleted')
      if (id === threadId) {
        navigate('/chats', { replace: true })
      }
    } catch {
      toast.error('Could not delete conversation.')
    }
  }

  return (
    <Sidebar>
      <SidebarHeader className="gap-3 p-3">
        <Logo className="px-1 py-1" />
        <Button
          variant="outline"
          className="w-full justify-start gap-2 border-dashed bg-background/50 text-muted-foreground hover:bg-muted/50"
          onClick={() => void handleNewChat()}
          disabled={isCreating}
        >
          <Plus className="h-4 w-4" />
          {isCreating ? 'Creating…' : 'New chat'}
        </Button>
      </SidebarHeader>

      <SidebarContent className="px-1">
        {isLoading ? (
          <div className="p-4 text-xs text-muted-foreground">Loading chats...</div>
        ) : null}

        {!isLoading && threads.length === 0 ? (
          <p className="px-3 py-2 text-xs text-muted-foreground">No conversations yet.</p>
        ) : null}

        {!isLoading &&
          groups.map((group) => (
            <SidebarGroup key={group.label}>
              <SidebarGroupLabel>{group.label}</SidebarGroupLabel>
              <SidebarGroupContent>
                <SidebarMenu>
                  {group.items.map((thread) => (
                    <SidebarMenuItem key={thread.id}>
                      <SidebarMenuButton
                        isActive={thread.id === threadId}
                        onClick={() => {
                          navigate(`/chats/${thread.id}`)
                          if (isMobile) setOpenMobile(false)
                        }}
                        className="pr-8"
                      >
                        <span className="truncate">{thread.title}</span>
                      </SidebarMenuButton>
                      <SidebarMenuAction
                        showOnHover
                        aria-label={`Delete conversation: ${thread.title}`}
                        title="Delete conversation"
                        className="text-muted-foreground hover:bg-destructive/10 hover:text-destructive"
                        onClick={(e) => {
                          e.stopPropagation()
                          void handleDeleteThread(thread.id)
                        }}
                      >
                        <Trash2 className="h-3.5 w-3.5" />
                      </SidebarMenuAction>
                    </SidebarMenuItem>
                  ))}
                </SidebarMenu>
              </SidebarGroupContent>
            </SidebarGroup>
          ))}
      </SidebarContent>

      <SidebarFooter>
        <UserMenu />
      </SidebarFooter>
    </Sidebar>
  )
}
INNER_EOF

# 15. Create frontend/src/components/chat/ThreadsProvider.tsx
cat << 'INNER_EOF' > frontend/src/components/chat/ThreadsProvider.tsx
import { useCallback, useEffect, useMemo, useState, type ReactNode } from 'react'
import { ThreadsContext } from '@/contexts/threads-context'
import { ApiError } from '@/lib/http'
import { createThread, deleteThread as deleteThreadRequest, listThreads } from '@/lib/chat'

export function ThreadsProvider({ children }: { children: ReactNode }) {
  const [threads, setThreads] = useState<Awaited<ReturnType<typeof listThreads>>>([])
  const [isLoading, setIsLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const refreshThreads = useCallback(async () => {
    setError(null)
    try {
      const nextThreads = await listThreads()
      setThreads(nextThreads)
    } catch (err) {
      if (err instanceof ApiError) {
        setError(err.message)
      } else {
        setError('Could not load conversations.')
      }
    }
  }, [])

  useEffect(() => {
    let mounted = true
    async function load() {
      setIsLoading(true)
      await refreshThreads()
      if (mounted) {
        setIsLoading(false)
      }
    }
    void load()
    return () => {
      mounted = false
    }
  }, [refreshThreads])

  const createNewThread = useCallback(async (title?: string) => {
    const thread = await createThread(title)
    await refreshThreads()
    return thread.id
  }, [refreshThreads])

  const deleteThread = useCallback(async (threadId: string) => {
    await deleteThreadRequest(threadId)
    setThreads((current) => current.filter((thread) => thread.id !== threadId))
  }, [])

  const value = useMemo(
    () => ({
      threads,
      isLoading,
      error,
      refreshThreads,
      createNewThread,
      deleteThread,
    }),
    [threads, isLoading, error, refreshThreads, createNewThread, deleteThread],
  )

  return <ThreadsContext.Provider value={value}>{children}</ThreadsContext.Provider>
}
INNER_EOF

# 16. Create frontend/src/components/chat/ChatLayout.tsx
cat << 'INNER_EOF' > frontend/src/components/chat/ChatLayout.tsx
import { Outlet, useParams } from 'react-router-dom'
import { ThreadSidebar } from '@/components/chat/ThreadSidebar'
import { ThreadsProvider } from '@/components/chat/ThreadsProvider'
import {
  SidebarInset,
  SidebarProvider,
  SidebarTrigger,
} from '@/components/ui/sidebar'
import { useThreads } from '@/hooks/useThreads'

function ChatHeader() {
  const { threadId } = useParams()
  const { threads } = useThreads()
  const activeThread = threads.find((thread) => thread.id === threadId)

  return (
    <header className="flex h-14 shrink-0 items-center gap-2 border-b bg-background/80 px-3 backdrop-blur">
      <SidebarTrigger className="text-muted-foreground" />
      <span className="truncate text-sm font-medium text-foreground">
        {activeThread?.title ?? 'Document Copilot'}
      </span>
    </header>
  )
}

function ChatLayoutContent() {
  return (
    <SidebarProvider>
      <ThreadSidebar />
      <SidebarInset className="flex h-svh min-h-0 flex-col bg-background">
        <ChatHeader />
        <div className="flex min-h-0 flex-1 flex-col">
          <Outlet />
        </div>
      </SidebarInset>
    </SidebarProvider>
  )
}

export function ChatLayout() {
  return (
    <ThreadsProvider>
      <ChatLayoutContent />
    </ThreadsProvider>
  )
}
INNER_EOF

# 17. Create frontend/src/pages/chat/ChatEmptyPage.tsx
cat << 'INNER_EOF' > frontend/src/pages/chat/ChatEmptyPage.tsx
import { useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { LogoMark } from '@/components/Logo'
import { useThreads } from '@/hooks/useThreads'

const EXAMPLE_QUESTIONS = [
  "Across Apple's 2021–2025 10-Ks, how did the revenue mix between iPhone, Services, Mac, and iPad change?",
  "For Amazon, compare AWS operating income and margin against North America and International from 2021–2025.",
  "How did NVIDIA describe demand drivers, customer concentration, and supply constraints for its Data Center business?",
  "Across Microsoft filings, what changed in how the company describes Azure, AI infrastructure, and cloud capacity constraints?",
] as const

export function ChatEmptyPage() {
  const navigate = useNavigate()
  const { createNewThread } = useThreads()
  const [isCreating, setIsCreating] = useState(false)

  async function handleStart(suggestion?: string) {
    if (isCreating) return
    setIsCreating(true)
    try {
      const id = await createNewThread(suggestion ? "New chat" : undefined)
      navigate(`/chats/${id}`, { state: { initialPrompt: suggestion } })
    } finally {
      setIsCreating(false)
    }
  }

  return (
    <div className="flex flex-1 flex-col items-center justify-center gap-8 p-6">
      <div className="flex flex-col items-center gap-4 text-center">
        <LogoMark className="size-12" />
        <div className="space-y-1.5">
          <h1 className="text-2xl font-semibold tracking-tight text-foreground">
            How can I help with your filings?
          </h1>
          <p className="max-w-md text-sm text-muted-foreground">
            Ask a question about SEC filings. Every answer is grounded in source documents
            with verifiable citations.
          </p>
        </div>
      </div>

      <div className="grid w-full max-w-xl gap-2 sm:grid-cols-2">
        {EXAMPLE_QUESTIONS.map((question) => (
          <button
            key={question}
            type="button"
            className="rounded-xl border border-border bg-background p-4 text-left text-sm hover:bg-muted/50 transition-colors"
            onClick={() => void handleStart(question)}
            disabled={isCreating}
          >
            {question}
          </button>
        ))}
      </div>
    </div>
  )
}
INNER_EOF

# 18. Create frontend/src/pages/chat/ChatThreadPage.tsx
cat << 'INNER_EOF' > frontend/src/pages/chat/ChatThreadPage.tsx
import { useEffect, useRef, useState } from 'react'
import { useNavigate, useParams, useLocation } from 'react-router-dom'
import { useChat } from '@ai-sdk/react'
import type { UIMessage } from 'ai'
import { ChatInput } from '@/components/chat/ChatInput'
import { MessageList } from '@/components/chat/MessageList'
import { SourcePassageSheet } from '@/components/chat/SourcePassageSheet'
import { useChatTransport } from '@/hooks/useChatTransport'
import { useThreads } from '@/hooks/useThreads'
import { getThreadMessages } from '@/lib/chat'
import type { PipelineStatus as PipelineStatusState, CitationPayload } from '@/lib/citations'

export function ChatThreadPage() {
  const { threadId } = useParams()
  const navigate = useNavigate()
  const location = useLocation()
  const { refreshThreads } = useThreads()
  const [pipelineStatus, setPipelineStatus] = useState<PipelineStatusState | null>(null)
  const [initialMessages, setInitialMessages] = useState<UIMessage[] | null>(null)
  const [selectedCitation, setSelectedCitation] = useState<CitationPayload | null>(null)
  
  const transport = useChatTransport(threadId || '', setPipelineStatus)

  useEffect(() => {
    if (!threadId) return
    let mounted = true

    async function load() {
      try {
        const msgs = await getThreadMessages(threadId!)
        if (mounted) {
          setInitialMessages(msgs)
        }
      } catch {
        if (mounted) {
          setInitialMessages([])
        }
      }
    }
    void load()
    return () => {
      mounted = false
    }
  }, [threadId])

  if (!threadId) return null

  if (initialMessages === null) {
    return (
      <div className="flex flex-1 items-center justify-center p-6 text-sm text-muted-foreground">
        Loading conversation history…
      </div>
    )
  }

  return (
    <ChatThreadView
      threadId={threadId}
      initialMessages={initialMessages}
      pipelineStatus={pipelineStatus}
      setPipelineStatus={setPipelineStatus}
      selectedCitation={selectedCitation}
      setSelectedCitation={setSelectedCitation}
      transport={transport}
      refreshThreads={refreshThreads}
      locationState={location.state}
    />
  )
}

type ChatThreadViewProps = {
  threadId: string
  initialMessages: UIMessage[]
  pipelineStatus: PipelineStatusState | null
  setPipelineStatus: (status: PipelineStatusState | null) => void
  selectedCitation: CitationPayload | null
  setSelectedCitation: (citation: CitationPayload | null) => void
  transport: any
  refreshThreads: () => Promise<void>
  locationState: any
}

function ChatThreadView({
  threadId,
  initialMessages,
  pipelineStatus,
  setPipelineStatus,
  selectedCitation,
  setSelectedCitation,
  transport,
  refreshThreads,
  locationState,
}: ChatThreadViewProps) {
  const { messages, sendMessage, status, stop } = useChat({
    id: threadId,
    messages: initialMessages,
    transport,
    onFinish: () => {
      setPipelineStatus(null)
      void refreshThreads()
    },
  })

  function send(text: string) {
    setPipelineStatus(null)
    setSelectedCitation(null)
    void sendMessage({ text })
  }

  const initialPrompt = locationState?.initialPrompt
  const sentInitial = useRef(false)
  useEffect(() => {
    if (!initialPrompt || sentInitial.current) return
    sentInitial.current = true
    send(initialPrompt)
  }, [initialPrompt])

  return (
    <div className="flex min-h-0 flex-1 flex-col bg-background">
      <MessageList
        messages={messages}
        status={status}
        pipelineStatus={pipelineStatus}
        selectedCitationIndex={selectedCitation?.citationIndex ?? null}
        onSelectCitation={setSelectedCitation}
        onSendSuggestion={send}
      />
      <ChatInput status={status} onSend={send} onStop={stop} />
      <SourcePassageSheet
        citation={selectedCitation}
        onOpenChange={(open) => {
          if (!open) setSelectedCitation(null)
        }}
      />
    </div>
  )
}
INNER_EOF

# 19. Update routing structure inside App.tsx
cat << 'INNER_EOF' > frontend/src/App.tsx
import { BrowserRouter, Navigate, Route, Routes } from 'react-router-dom'
import { ProtectedRoute } from '@/components/ProtectedRoute'
import { PublicRoute } from '@/components/PublicRoute'
import { Login } from '@/pages/Login'
import { SignUp } from '@/pages/SignUp'
import { ChatLayout } from '@/components/chat/ChatLayout'
import { ChatEmptyPage } from '@/pages/chat/ChatEmptyPage'
import { ChatThreadPage } from '@/pages/chat/ChatThreadPage'

function App() {
  return (
    <BrowserRouter>
      <Routes>
        <Route
          path="/login"
          element={
            <PublicRoute>
              <Login />
            </PublicRoute>
          }
        />
        <Route
          path="/signup"
          element={
            <PublicRoute>
              <SignUp />
            </PublicRoute>
          }
        />
        <Route
          path="/chats"
          element={
            <ProtectedRoute>
              <ChatLayout />
            </ProtectedRoute>
          }
        >
          <Route index element={<ChatEmptyPage />} />
          <Route path=":threadId" element={<ChatThreadPage />} />
        </Route>
        <Route path="*" element={<Navigate to="/chats" replace />} />
      </Routes>
    </BrowserRouter>
  )
}

export default App
INNER_EOF

echo "Frontend Chat Shell setup complete! Clean up script."
rm setup_frontend_phase7.sh
EOF

# Run the script to generate all frontend files
bash setup_frontend_phase7.sh