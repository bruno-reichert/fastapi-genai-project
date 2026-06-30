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
      <div className="mx-auto w-full max-w-3xl flex items-end gap-2 border border-input rounded-xl p-2 bg-background">
        <textarea
          rows={1}
          value={input}
          onChange={(e) => setInput(e.target.value)}
          onKeyDown={handleKeyDown}
          placeholder="Ask about SEC filings…"
          className="flex-1 max-h-48 min-h-9 resize-none bg-transparent py-1.5 px-3 outline-none text-sm leading-relaxed"
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
