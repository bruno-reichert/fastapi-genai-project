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
