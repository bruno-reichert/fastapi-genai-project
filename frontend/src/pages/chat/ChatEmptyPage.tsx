import { useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { LogoMark } from '@/components/Logo'
import { useThreads } from '@/hooks/useThreads'

const SUGGESTIONS = [
  "Across Apple's 2021–2025 10-Ks, how did the revenue mix between iPhone, Services, Mac, iPad, and Wearables change?",
  "For Amazon, compare AWS operating income and margin against North America and International from 2021–2025.",
  "How did NVIDIA describe demand drivers, customer concentration, and supply constraints for its Data Center business?",
  "Across Microsoft filings, what changed in how the company describes Azure, AI infrastructure, and cloud capacity constraints?",
]

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

const EXAMPLE_QUESTIONS = [
  "Across Apple's 2021–2025 10-Ks, how did the revenue mix between iPhone, Services, Mac, iPad, and Wearables change?",
  "For Amazon, compare AWS operating income and margin against North America and International from 2021–2025.",
  "How did NVIDIA describe demand drivers, customer concentration, and supply constraints for its Data Center business?",
  "Across Microsoft filings, what changed in how the company describes Azure, AI infrastructure, and cloud capacity constraints?",
]
