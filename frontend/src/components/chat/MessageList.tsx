import type { ChatStatus, UIMessage } from 'ai'
import { StickToBottom } from 'use-stick-to-bottom'

import { MessageBubble } from '@/components/chat/MessageBubble'
import { PipelineStatus } from '@/components/chat/PipelineStatus'
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