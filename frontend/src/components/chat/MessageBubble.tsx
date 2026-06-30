import type { UIMessage } from 'ai'
import { textFromMessage } from '@/lib/citations'

type MessageBubbleProps = {
  message: UIMessage
}

export function MessageBubble({ message }: MessageBubbleProps) {
  const isAssistant = message.role === 'assistant'
  const text = textFromMessage(message)

  return (
    <div className={isAssistant ? "flex justify-start" : "flex justify-end"}>
      <div
        className={
          isAssistant
            ? "max-w-[80%] rounded-2xl rounded-bl-md bg-muted px-4 py-2.5 text-sm leading-relaxed whitespace-pre-wrap text-foreground"
            : "max-w-[80%] rounded-2xl rounded-br-md bg-primary px-4 py-2.5 text-sm leading-relaxed whitespace-pre-wrap text-primary-foreground"
        }
      >
        {text}
      </div>
    </div>
  )
}
