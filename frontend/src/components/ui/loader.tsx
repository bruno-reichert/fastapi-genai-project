import { cn } from "@/lib/utils"

export interface LoaderProps {
  variant?:
    | "circular"
    | "classic"
    | "pulse"
    | "pulse-dot"
    | "dots"
    | "typing"
    | "wave"
    | "bars"
    | "terminal"
    | "text-blink"
    | "text-shimmer"
    | "loading-dots"
  size?: "sm" | "md" | "lg"
  text?: string
  className?: string
}

export function Loader({
  variant = "circular",
  size = "md",
  text,
  className,
}: LoaderProps) {
  return (
    <div className={cn("inline-flex items-center gap-2", className)}>
      <div className="animate-spin rounded-full border-2 border-primary border-t-transparent h-4 w-4 shrink-0" />
      {text && <span className="text-xs text-muted-foreground">{text}</span>}
    </div>
  )
}