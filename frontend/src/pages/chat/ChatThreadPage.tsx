import { useEffect, useState } from 'react'
import { useParams, useLocation } from 'react-router-dom'
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
  const location = useLocation()
  const { refreshThreads } = useThreads()
  const [pipelineStatus, setPipelineStatus] = useState<PipelineStatusState | null>(null)
  const [initialMessages, setInitialMessages] = useState<UIMessage[] | null>(null)
  const [selectedCitation, setSelectedCitation] = useState<CitationPayload | null>(null)
  
  const transport = useChatTransport(threadId || '')

  useEffect(() => {
    if (!threadId) return
    let mounted = true

    async function load() {
      // Clear history cache immediately on thread change to prevent mounting with stale state
      setInitialMessages(null)
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
      <div className="flex flex-1 items-center justify-center p-6 text-sm text-muted-foreground bg-background">
        Loading conversation history…
      </div>
    )
  }

  return (
    <ChatThreadView
      key={threadId} // Forces complete state unmount and re-mount on navigation change
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

  // Auto-trigger prompt forwarded from Suggestion buttons
  const initialPrompt = locationState?.initialPrompt
  const sentInitial = useRef(false)
  
  // Custom safe ref trigger matching standard typing cycles
  const ref = useRef<HTMLDivElement>(null)
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
      <div ref={ref} className="h-0" />
      <SourcePassageSheet
        citation={selectedCitation}
        onOpenChange={(open) => {
          if (!open) setSelectedCitation(null)
        }}
      />
    </div>
  )
}

// Inline helper to bypass React ref compiler scopes inside the render thread
import { useRef } from 'react'