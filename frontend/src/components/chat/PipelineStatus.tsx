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
      className="w-fit text-sm font-medium text-muted-foreground animate-pulse"
    >
      {message}
    </p>
  )
}
