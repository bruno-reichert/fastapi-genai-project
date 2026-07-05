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
