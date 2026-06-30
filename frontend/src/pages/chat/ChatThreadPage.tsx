import { useEffect, useRef, useState } from 'react'
import { useNavigate, useParams, useLocation } from 'react-router-dom'
import { useChat } from '@ai-sdk/react'
import type { UIMessage } from 'ai'
import { ChatInput } from '@/components/chat/ChatInput'
import { MessageList } from '@/components/chat/MessageList'
import { useChatTransport } from '@/hooks/useChatTransport'
import { useThreads } from '@/hooks/useThreads'
import { getThreadMessages } from '@/lib/chat'
import type { PipelineStatus as PipelineStatusState } from '@/lib/citations'

export function ChatThreadPage() {
  const { threadId } = useParams()
  const navigate = useNavigate()
  const location = useLocation()
  const { refreshThreads } = useThreads()
  const [pipelineStatus, setPipelineStatus] = useState<PipelineStatusState | null>(null)
  const [initialMessages, setInitialMessages] = useState<UIMessage[] | null>(null)
  
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
  transport: any
  refreshThreads: () => Promise<void>
  locationState: any
}

function ChatThreadView({
  threadId,
  initialMessages,
  pipelineStatus,
  setPipelineStatus,
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
    void sendMessage({ text })
  }

  // Trigger prompt forwarded from home page Suggestion
  const initialPrompt = locationState?.initialPrompt
  const sentInitial = useRef(false)
  useEffect(() => {
    if (!initialPrompt || sentInitial.current) return
    sentInitial.current = true
    send(initialPrompt)
  }, [initialPrompt])

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <MessageList
        messages={messages}
        status={status}
        pipelineStatus={pipelineStatus}
        onSendSuggestion={send}
      />
      <ChatInput status={status} onSend={send} onStop={stop} />
    </div>
  )
}
