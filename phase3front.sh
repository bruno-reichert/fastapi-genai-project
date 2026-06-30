# Execute from your repository root
cat << 'EOF' > setup_frontend_chat_shell.sh
#!/bin/bash
set -e

# 1. Install required packages in the frontend workspace
cd frontend
pnpm add ai @ai-sdk/react sonner use-stick-to-bottom @radix-ui/react-tooltip @radix-ui/react-avatar @radix-ui/react-dropdown-menu @radix-ui/react-separator @radix-ui/react-dialog @radix-ui/react-alert-dialog
cd ..

# Create directory structures
mkdir -p frontend/src/components/ui
mkdir -p frontend/src/components/chat
mkdir -p frontend/src/contexts
mkdir -p frontend/src/hooks
mkdir -p frontend/src/lib
mkdir -p frontend/src/pages/chat

# 2. Generate standard shadcn / Radix primitives
cat << 'INNER_EOF' > frontend/src/components/ui/tooltip.tsx
import * as React from "react"
import * as TooltipPrimitive from "@radix-ui/react-tooltip"
import { cn } from "@/lib/utils"

function TooltipProvider({
  delayDuration = 0,
  ...props
}: React.ComponentProps<typeof TooltipPrimitive.Provider>) {
  return (
    <TooltipPrimitive.Provider
      data-slot="tooltip-provider"
      delayDuration={delayDuration}
      {...props}
    />
  )
}

function Tooltip({
  ...props
}: React.ComponentProps<typeof TooltipPrimitive.Root>) {
  return <TooltipPrimitive.Root data-slot="tooltip" {...props} />
}

function TooltipTrigger({
  ...props
}: React.ComponentProps<typeof TooltipPrimitive.Trigger>) {
  return <TooltipPrimitive.Trigger data-slot="tooltip-trigger" {...props} />
}

function TooltipContent({
  className,
  sideOffset = 4,
  children,
  ...props
}: React.ComponentProps<typeof TooltipPrimitive.Content>) {
  return (
    <TooltipPrimitive.Portal>
      <TooltipPrimitive.Content
        data-slot="tooltip-content"
        sideOffset={sideOffset}
        className={cn(
          "z-50 inline-flex w-fit max-w-xs items-center gap-1.5 rounded-md bg-foreground px-3 py-1.5 text-xs text-background",
          className
        )}
        {...props}
      >
        {children}
        <TooltipPrimitive.Arrow className="z-50 size-2.5 fill-foreground" />
      </TooltipPrimitive.Content>
    </TooltipPrimitive.Portal>
  )
}

export { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger }
INNER_EOF

cat << 'INNER_EOF' > frontend/src/components/ui/separator.tsx
import * as React from "react"
import * as SeparatorPrimitive from "@radix-ui/react-separator"
import { cn } from "@/lib/utils"

function Separator({
  className,
  orientation = "horizontal",
  decorative = true,
  ...props
}: React.ComponentProps<typeof SeparatorPrimitive.Root>) {
  return (
    <SeparatorPrimitive.Root
      data-slot="separator"
      decorative={decorative}
      orientation={orientation}
      className={cn(
        "shrink-0 bg-border",
        orientation === "horizontal" ? "h-px w-full" : "h-full w-px",
        className
      )}
      {...props}
    />
  )
}

export { Separator }
INNER_EOF

cat << 'INNER_EOF' > frontend/src/components/ui/skeleton.tsx
import { cn } from "@/lib/utils"

function Skeleton({ className, ...props }: React.ComponentProps<"div">) {
  return (
    <div
      data-slot="skeleton"
      className={cn("animate-pulse rounded-md bg-muted", className)}
      {...props}
    />
  )
}

export { Skeleton }
INNER_EOF

cat << 'INNER_EOF' > frontend/src/components/ui/avatar.tsx
import * as React from "react"
import * as AvatarPrimitive from "@radix-ui/react-avatar"
import { cn } from "@/lib/utils"

function Avatar({
  className,
  ...props
}: React.ComponentProps<typeof AvatarPrimitive.Root>) {
  return (
    <AvatarPrimitive.Root
      data-slot="avatar"
      className={cn(
        "relative flex h-8 w-8 shrink-0 overflow-hidden rounded-full",
        className
      )}
      {...props}
    />
  )
}

function AvatarImage({
  className,
  ...props
}: React.ComponentProps<typeof AvatarPrimitive.Image>) {
  return (
    <AvatarPrimitive.Image
      data-slot="avatar-image"
      className={cn("aspect-square h-full w-full", className)}
      {...props}
    />
  )
}

function AvatarFallback({
  className,
  ...props
}: React.ComponentProps<typeof AvatarPrimitive.Fallback>) {
  return (
    <AvatarPrimitive.Fallback
      data-slot="avatar-fallback"
      className={cn(
        "flex h-full w-full items-center justify-center rounded-full bg-muted text-sm font-medium",
        className
      )}
      {...props}
    />
  )
}

export { Avatar, AvatarImage, AvatarFallback }
INNER_EOF

cat << 'INNER_EOF' > frontend/src/components/ui/dropdown-menu.tsx
import * as React from "react"
import * as DropdownMenuPrimitive from "@radix-ui/react-dropdown-menu"
import { cn } from "@/lib/utils"

function DropdownMenu({
  ...props
}: React.ComponentProps<typeof DropdownMenuPrimitive.Root>) {
  return <DropdownMenuPrimitive.Root data-slot="dropdown-menu" {...props} />
}

function DropdownMenuTrigger({
  ...props
}: React.ComponentProps<typeof DropdownMenuPrimitive.Trigger>) {
  return <DropdownMenuPrimitive.Trigger data-slot="dropdown-menu-trigger" {...props} />
}

function DropdownMenuContent({
  className,
  align = "start",
  sideOffset = 4,
  ...props
}: React.ComponentProps<typeof DropdownMenuPrimitive.Content>) {
  return (
    <DropdownMenuPrimitive.Portal>
      <DropdownMenuPrimitive.Content
        data-slot="dropdown-menu-content"
        sideOffset={sideOffset}
        align={align}
        className={cn(
          "z-50 min-w-[8rem] overflow-hidden rounded-md border bg-popover p-1 text-popover-foreground shadow-md",
          className
        )}
        {...props}
      />
    </DropdownMenuPrimitive.Portal>
  )
}

function DropdownMenuItem({
  className,
  ...props
}: React.ComponentProps<typeof DropdownMenuPrimitive.Item>) {
  return (
    <DropdownMenuPrimitive.Item
      data-slot="dropdown-menu-item"
      className={cn(
        "relative flex cursor-default select-none items-center rounded-sm px-2 py-1.5 text-sm outline-none transition-colors focus:bg-accent focus:text-accent-foreground data-disabled:pointer-events-none data-disabled:opacity-50",
        className
      )}
      {...props}
    />
  )
}

function DropdownMenuLabel({
  className,
  ...props
}: React.ComponentProps<typeof DropdownMenuPrimitive.Label>) {
  return (
    <DropdownMenuPrimitive.Label
      data-slot="dropdown-menu-label"
      className={cn("px-2 py-1.5 text-sm font-semibold", className)}
      {...props}
    />
  )
}

function DropdownMenuSeparator({
  className,
  ...props
}: React.ComponentProps<typeof DropdownMenuPrimitive.Separator>) {
  return (
    <DropdownMenuPrimitive.Separator
      data-slot="dropdown-menu-separator"
      className={cn("-mx-1 my-1 h-px bg-muted", className)}
      {...props}
    />
  )
}

export {
  DropdownMenu,
  DropdownMenuTrigger,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
}
INNER_EOF

cat << 'INNER_EOF' > frontend/src/components/ui/sheet.tsx
import * as React from "react"
import * as SheetPrimitive from "@radix-ui/react-dialog"
import { cn } from "@/lib/utils"

function Sheet({ ...props }: React.ComponentProps<typeof SheetPrimitive.Root>) {
  return <SheetPrimitive.Root data-slot="sheet" {...props} />
}

function SheetTrigger({
  ...props
}: React.ComponentProps<typeof SheetPrimitive.Trigger>) {
  return <SheetPrimitive.Trigger data-slot="sheet-trigger" {...props} />
}

function SheetClose({
  ...props
}: React.ComponentProps<typeof SheetPrimitive.Close>) {
  return <SheetPrimitive.Close data-slot="sheet-close" {...props} />
}

function SheetPortal({
  ...props
}: React.ComponentProps<typeof SheetPrimitive.Portal>) {
  return <SheetPrimitive.Portal data-slot="sheet-portal" {...props} />
}

function SheetOverlay({
  className,
  ...props
}: React.ComponentProps<typeof SheetPrimitive.Overlay>) {
  return (
    <SheetPrimitive.Overlay
      data-slot="sheet-overlay"
      className={cn(
        "fixed inset-0 z-50 bg-black/80 data-[state=open]:animate-in data-[state=closed]:animate-out data-[state=closed]:fade-out-0 data-[state=open]:fade-in-0",
        className
      )}
      {...props}
    />
  )
}

function SheetContent({
  className,
  children,
  side = "right",
  ...props
}: React.ComponentProps<typeof SheetPrimitive.Content> & {
  side?: "top" | "right" | "bottom" | "left"
}) {
  return (
    <SheetPortal>
      <SheetOverlay />
      <SheetPrimitive.Content
        data-slot="sheet-content"
        className={cn(
          "fixed z-50 gap-4 bg-background p-6 shadow-lg transition ease-in-out data-[state=open]:animate-in data-[state=closed]:animate-out data-[state=closed]:duration-300 data-[state=open]:duration-500",
          side === "right" && "inset-y-0 right-0 h-full w-3/4 border-l data-[state=closed]:slide-out-to-right data-[state=open]:slide-in-from-right sm:max-w-sm",
          side === "left" && "inset-y-0 left-0 h-full w-3/4 border-r data-[state=closed]:slide-out-to-left data-[state=open]:slide-in-from-left sm:max-w-sm",
          className
        )}
        {...props}
      >
        {children}
      </SheetPrimitive.Content>
    </SheetPortal>
  )
}

export {
  Sheet,
  SheetTrigger,
  SheetClose,
  SheetContent,
}
INNER_EOF

cat << 'INNER_EOF' > frontend/src/components/ui/sidebar.tsx
import * as React from "react"
import { useIsMobile } from "@/hooks/use-mobile"
import { cn } from "@/lib/utils"
import { Sheet, SheetContent } from "@/components/ui/sheet"
import { PanelLeft } from "lucide-react"
import { Button } from "@/components/ui/button"

const SIDEBAR_WIDTH = "16rem"
const SIDEBAR_WIDTH_ICON = "3rem"

type SidebarContextProps = {
  state: "expanded" | "collapsed"
  open: boolean
  setOpen: (open: boolean) => void
  openMobile: boolean
  setOpenMobile: (open: boolean) => void
  isMobile: boolean
  toggleSidebar: () => void
}

const SidebarContext = React.createContext<SidebarContextProps | null>(null)

export function useSidebar() {
  const context = React.useContext(SidebarContext)
  if (!context) {
    throw new Error("useSidebar must be used within a SidebarProvider.")
  }
  return context
}

export function SidebarProvider({
  defaultOpen = true,
  open: openProp,
  onOpenChange: setOpenProp,
  className,
  style,
  children,
  ...props
}: React.ComponentProps<"div"> & {
  defaultOpen?: boolean
  open?: boolean
  onOpenChange?: (open: boolean) => void
}) {
  const isMobile = useIsMobile()
  const [openMobile, setOpenMobile] = React.useState(false)
  const [_open, _setOpen] = React.useState(defaultOpen)
  const open = openProp ?? _open

  const setOpen = React.useCallback(
    (value: boolean | ((value: boolean) => boolean)) => {
      const openState = typeof value === "function" ? value(open) : value
      if (setOpenProp) {
        setOpenProp(openState)
      } else {
        _setOpen(openState)
      }
    },
    [setOpenProp, open]
  )

  const toggleSidebar = React.useCallback(() => {
    return isMobile ? setOpenMobile((o) => !atob) : setOpen((o) => !o)
  }, [isMobile, setOpen, setOpenMobile])

  const state = open ? "expanded" : "collapsed"

  const contextValue = React.useMemo<SidebarContextProps>(
    () => ({
      state,
      open,
      setOpen,
      isMobile,
      openMobile,
      setOpenMobile,
      toggleSidebar,
    }),
    [state, open, setOpen, isMobile, openMobile, setOpenMobile, toggleSidebar]
  )

  return (
    <SidebarContext.Provider value={contextValue}>
      <div
        style={
          {
            "--sidebar-width": SIDEBAR_WIDTH,
            "--sidebar-width-icon": SIDEBAR_WIDTH_ICON,
            ...style,
          } as React.CSSProperties
        }
        className={cn(
          "group/sidebar-wrapper flex min-h-svh w-full bg-sidebar",
          className
        )}
        {...props}
      >
        {children}
      </div>
    </SidebarContext.Provider>
  )
}

export function Sidebar({
  className,
  children,
  ...props
}: React.ComponentProps<"div">) {
  const { isMobile, state, openMobile, setOpenMobile } = useSidebar()

  if (isMobile) {
    return (
      <Sheet open={openMobile} onOpenChange={setOpenMobile} {...props}>
        <SheetContent
          className="w-(--sidebar-width) bg-sidebar p-0 text-sidebar-foreground"
          side="left"
        >
          <div className="flex h-full w-full flex-col">{children}</div>
        </SheetContent>
      </Sheet>
    )
  }

  return (
    <div
      className="group peer hidden text-sidebar-foreground md:block"
      data-state={state}
    >
      <div
        className={cn(
          "duration-200 relative h-svh w-(--sidebar-width) bg-sidebar transition-[width] ease-linear",
          "group-data-[state=collapsed]:w-(--sidebar-width-icon)"
        )}
      />
      <div
        className={cn(
          "duration-200 fixed inset-y-0 left-0 z-10 hidden h-svh w-(--sidebar-width) transition-[width] ease-linear md:flex border-r border-sidebar-border bg-sidebar",
          "group-data-[state=collapsed]:w-(--sidebar-width-icon)",
          className
        )}
        {...props}
      >
        <div className="flex h-full w-full flex-col">{children}</div>
      </div>
    </div>
  )
}

export function SidebarTrigger({
  className,
  onClick,
  ...props
}: React.ComponentProps<typeof Button>) {
  const { toggleSidebar } = useSidebar()

  return (
    <Button
      variant="ghost"
      size="icon"
      className={cn("h-7 w-7", className)}
      onClick={(e) => {
        onClick?.(e)
        toggleSidebar()
      }}
      {...props}
    >
      <PanelLeft className="h-4 w-4" />
      <span className="sr-only">Toggle Sidebar</span>
    </Button>
  )
}

export function SidebarInset({ className, ...props }: React.ComponentProps<"main">) {
  return (
    <main
      className={cn(
        "relative flex min-h-svh flex-1 flex-col bg-background",
        className
      )}
      {...props}
    />
  )
}

export function SidebarHeader({ className, ...props }: React.ComponentProps<"div">) {
  return (
    <div
      className={cn("flex flex-col gap-2 p-2 border-b border-sidebar-border", className)}
      {...props}
    />
  )
}

export function SidebarContent({ className, ...props }: React.ComponentProps<"div">) {
  return (
    <div
      className={cn(
        "flex min-h-0 flex-1 flex-col gap-2 overflow-y-auto overflow-x-hidden",
        className
      )}
      {...props}
    />
  )
}

export function SidebarGroup({ className, ...props }: React.ComponentProps<"div">) {
  return (
    <div
      className={cn("relative flex w-full min-w-0 flex-col p-2", className)}
      {...props}
    />
  )
}

export function SidebarGroupLabel({ className, ...props }: React.ComponentProps<"div">) {
  return (
    <div
      className={cn(
        "flex h-8 shrink-0 items-center rounded-md px-2 text-xs font-semibold text-sidebar-foreground/50",
        className
      )}
      {...props}
    />
  )
}

export function SidebarGroupContent({ className, ...props }: React.ComponentProps<"div">) {
  return (
    <div
      className={cn("w-full text-sm", className)}
      {...props}
    />
  )
}

export function SidebarMenu({ className, ...props }: React.ComponentProps<"ul">) {
  return (
    <ul
      className={cn("flex w-full min-w-0 flex-col gap-1", className)}
      {...props}
    />
  )
}

export function SidebarMenuItem({ className, ...props }: React.ComponentProps<"li">) {
  return (
    <li
      className={cn("group/menu-item relative list-none", className)}
      {...props}
    />
  )
}

export function SidebarMenuButton({
  className,
  isActive,
  ...props
}: React.ComponentProps<"button"> & { isActive?: boolean }) {
  return (
    <button
      className={cn(
        "flex w-full items-center gap-2 rounded-md p-2 text-left text-sm transition-colors hover:bg-sidebar-accent hover:text-sidebar-accent-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring disabled:pointer-events-none disabled:opacity-50",
        isActive && "bg-sidebar-accent text-sidebar-accent-foreground font-medium",
        className
      )}
      {...props}
    />
  )
}

export function SidebarMenuAction({
  className,
  showOnHover,
  ...props
}: React.ComponentProps<"button"> & { showOnHover?: boolean }) {
  return (
    <button
      className={cn(
        "absolute right-1 top-1.5 flex h-5 w-5 items-center justify-center rounded-md p-0 text-sidebar-foreground transition-all hover:bg-sidebar-accent hover:text-sidebar-accent-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring",
        showOnHover && "opacity-0 group-hover/menu-item:opacity-100 focus-visible:opacity-100",
        className
      )}
      {...props}
    />
  )
}

export function SidebarFooter({ className, ...props }: React.ComponentProps<"div">) {
  return (
    <div
      className={cn("flex flex-col gap-2 p-2 border-t border-sidebar-border mt-auto", className)}
      {...props}
    />
  )
}
INNER_EOF

cat << 'INNER_EOF' > frontend/src/components/ui/alert-dialog.tsx
import * as React from "react"
import * as AlertDialogPrimitive from "@radix-ui/react-alert-dialog"
import { cn } from "@/lib/utils"
import { buttonVariants } from "@/components/ui/button"

function AlertDialog({
  ...props
}: React.ComponentProps<typeof AlertDialogPrimitive.Root>) {
  return <AlertDialogPrimitive.Root data-slot="alert-dialog" {...props} />
}

function AlertDialogTrigger({
  ...props
}: React.ComponentProps<typeof AlertDialogPrimitive.Trigger>) {
  return <AlertDialogPrimitive.Trigger data-slot="alert-dialog-trigger" {...props} />
}

function AlertDialogPortal({
  ...props
}: React.ComponentProps<typeof AlertDialogPrimitive.Portal>) {
  return <AlertDialogPrimitive.Portal data-slot="alert-dialog-portal" {...props} />
}

function AlertDialogOverlay({
  className,
  ...props
}: React.ComponentProps<typeof AlertDialogPrimitive.Overlay>) {
  return (
    <AlertDialogPrimitive.Overlay
      data-slot="alert-dialog-overlay"
      className={cn(
        "fixed inset-0 z-50 bg-black/80 data-[state=open]:animate-in data-[state=closed]:animate-out data-[state=closed]:fade-out-0 data-[state=open]:fade-in-0",
        className
      )}
      {...props}
    />
  )
}

function AlertDialogContent({
  className,
  ...props
}: React.ComponentProps<typeof AlertDialogPrimitive.Content>) {
  return (
    <AlertDialogPortal>
      <AlertDialogOverlay />
      <AlertDialogPrimitive.Content
        data-slot="alert-dialog-content"
        className={cn(
          "fixed left-[50%] top-[50%] z-50 grid w-full max-w-lg translate-x-[50%] translate-y-[50%] gap-4 border bg-background p-6 shadow-lg duration-200 data-[state=open]:animate-in data-[state=closed]:animate-out data-[state=closed]:fade-out-0 data-[state=open]:fade-in-0 data-[state=closed]:zoom-out-95 data-[state=open]:zoom-in-95 data-[state=closed]:slide-out-to-left-[50%] data-[state=closed]:slide-out-to-top-[50%] data-[state=open]:slide-in-from-left-[50%] data-[state=open]:slide-in-from-top-[50%] sm:rounded-lg",
          className
        )}
        {...props}
      />
    </AlertDialogPortal>
  )
}

function AlertDialogHeader({
  className,
  ...props
}: React.ComponentProps<"div">) {
  return (
    <div
      data-slot="alert-dialog-header"
      className={cn(
        "flex flex-col space-y-2 text-center sm:text-left",
        className
      )}
      {...props}
    />
  )
}

function AlertDialogFooter({
  className,
  ...props
}: React.ComponentProps<"div">) {
  return (
    <div
      data-slot="alert-dialog-footer"
      className={cn(
        "flex flex-col-reverse sm:flex-row sm:justify-end sm:space-x-2",
        className
      )}
      {...props}
    />
  )
}

function AlertDialogTitle({
  className,
  ...props
}: React.ComponentProps<typeof AlertDialogPrimitive.Title>) {
  return (
    <AlertDialogPrimitive.Title
      data-slot="alert-dialog-title"
      className={cn("text-lg font-semibold", className)}
      {...props}
    />
  )
}

function AlertDialogDescription({
  className,
  ...props
}: React.ComponentProps<typeof AlertDialogPrimitive.Description>) {
  return (
    <AlertDialogPrimitive.Description
      data-slot="alert-dialog-description"
      className={cn("text-sm text-muted-foreground", className)}
      {...props}
    />
  )
}

function AlertDialogAction({
  className,
  ...props
}: React.ComponentProps<typeof AlertDialogPrimitive.Action>) {
  return (
    <AlertDialogPrimitive.Action
      data-slot="alert-dialog-action"
      className={cn(buttonVariants(), className)}
      {...props}
    />
  )
}

function AlertDialogCancel({
  className,
  ...props
}: React.ComponentProps<typeof AlertDialogPrimitive.Cancel>) {
  return (
    <AlertDialogPrimitive.Cancel
      data-slot="alert-dialog-cancel"
      className={cn(
        buttonVariants({ variant: "outline" }),
        "mt-2 sm:mt-0",
        className
      )}
      {...props}
    />
  )
}

export {
  AlertDialog,
  AlertDialogPortal,
  AlertDialogOverlay,
  AlertDialogTrigger,
  AlertDialogContent,
  AlertDialogHeader,
  AlertDialogFooter,
  AlertDialogTitle,
  AlertDialogDescription,
  AlertDialogAction,
  AlertDialogCancel,
}
INNER_EOF

cat << 'INNER_EOF' > frontend/src/components/ui/sonner.tsx
import { Toaster as Sonner } from "sonner"

type ToasterProps = React.ComponentProps<typeof Sonner>

function Toaster({ ...props }: ToasterProps) {
  return (
    <Sonner
      className="toaster group"
      toastOptions={{
        classNames: {
          toast:
            "group toast group-[.toaster]:bg-background group-[.toaster]:text-foreground group-[.toaster]:border-border group-[.toaster]:shadow-lg",
          description: "group-[.toast]:text-muted-foreground",
          actionButton:
            "group-[.toast]:bg-primary group-[.toast]:text-primary-foreground",
          cancelButton:
            "group-[.toast]:bg-muted group-[.toast]:text-muted-foreground",
        },
      }}
      {...props}
    />
  )
}

export { Toaster }
INNER_EOF

# 3. Create utility components & formatting helpers
cat << 'INNER_EOF' > frontend/src/lib/citations.ts
import { isDataUIPart, type UIMessage } from 'ai'

export type PipelineStage =
  | 'analyzing'
  | 'searching'
  | 'reading'
  | 'verifying'
  | 'streaming'

export type PipelineStatus = {
  stage: PipelineStage
  message: string
}

export function isStatusPart(
  part: unknown,
): part is { type: 'data-status'; data: PipelineStatus } {
  if (typeof part !== 'object' || part === null) {
    return false
  }

  const record = part as Record<string, unknown>
  if (record.type !== 'data-status' || typeof record.data !== 'object' || record.data === null) {
    return false
  }

  const data = record.data as Record<string, unknown>
  return typeof data.stage === 'string' && typeof data.message === 'string'
}

export function textFromMessage(message: UIMessage): string {
  return message.parts
    .filter((part) => part.type === 'text')
    .map((part) => part.text)
    .join('')
}
INNER_EOF

cat << 'INNER_EOF' > frontend/src/lib/format.ts
export type RecencyGroup = 'Today' | 'Yesterday' | 'Previous 7 days' | 'Older'

const RECENCY_ORDER: RecencyGroup[] = ['Today', 'Yesterday', 'Previous 7 days', 'Older']

function startOfDay(date: Date): number {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime()
}

export function recencyGroup(isoDate: string): RecencyGroup {
  const date = new Date(isoDate)
  const today = startOfDay(new Date())
  const dayMs = 24 * 60 * 60 * 1000
  const dayStart = startOfDay(date)

  if (dayStart >= today) return 'Today'
  if (dayStart >= today - dayMs) return 'Yesterday'
  if (dayStart >= today - 7 * dayMs) return 'Previous 7 days'
  return 'Older'
}

export function groupByRecency<T>(
  items: T[],
  getDate: (item: T) => string,
): Array<{ label: RecencyGroup; items: T[] }> {
  const buckets = new Map<RecencyGroup, T[]>()
  for (const item of items) {
    const group = recencyGroup(getDate(item))
    const bucket = buckets.get(group) ?? []
    bucket.push(item)
    buckets.set(group, bucket)
  }

  return RECENCY_ORDER.filter((label) => buckets.has(label)).map((label) => ({
    label,
    items: buckets.get(label)!,
  }))
}
INNER_EOF

cat << 'INNER_EOF' > frontend/src/lib/chat.ts
import { api } from '@/lib/api'
import type { UIMessage } from 'ai'

export type ThreadSummary = {
  id: string
  title: string
  createdAt: string
  updatedAt: string
}

type ThreadListResponse = {
  threads: ThreadSummary[]
}

type MessageHistoryResponse = {
  messages: UIMessage[]
}

export async function listThreads(): Promise<ThreadSummary[]> {
  const response = await api.get<ThreadListResponse>('/chat/threads')
  return response.threads
}

export async function createThread(title?: string): Promise<ThreadSummary> {
  return api.post<ThreadSummary>('/chat/threads', title ? { title } : {})
}

export async function deleteThread(threadId: string): Promise<void> {
  await api.delete<void>(`/chat/threads/${threadId}`)
}

export async function getThreadMessages(threadId: string): Promise<UIMessage[]> {
  const response = await api.get<MessageHistoryResponse>(
    `/chat/threads/${threadId}/messages`,
  )
  return response.messages
}
INNER_EOF

# 4. Create thread routing state structures
cat << 'INNER_EOF' > frontend/src/contexts/threads-context.ts
import { createContext } from 'react'
import type { ThreadSummary } from '@/lib/chat'

export type ThreadsContextValue = {
  threads: ThreadSummary[]
  isLoading: boolean
  error: string | null
  refreshThreads: () => Promise<void>
  createNewThread: (title?: string) => Promise<string>
  deleteThread: (threadId: string) => Promise<void>
}

export const ThreadsContext = createContext<ThreadsContextValue | null>(null)
INNER_EOF

cat << 'INNER_EOF' > frontend/src/components/chat/ThreadsProvider.tsx
import { useCallback, useEffect, useMemo, useState, type ReactNode } from 'react'
import { ThreadsContext } from '@/contexts/threads-context'
import { ApiError } from '@/lib/http'
import { createThread, deleteThread as deleteThreadRequest, listThreads } from '@/lib/chat'

export function ThreadsProvider({ children }: { children: ReactNode }) {
  const [threads, setThreads] = useState<Awaited<ReturnType<typeof listThreads>>>([])
  const [isLoading, setIsLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const refreshThreads = useCallback(async () => {
    setError(null)
    try {
      const nextThreads = await listThreads()
      setThreads(nextThreads)
    } catch (err) {
      if (err instanceof ApiError) {
        setError(err.message)
      } else {
        setError('Could not load conversations.')
      }
    }
  }, [])

  useEffect(() => {
    let mounted = true
    async function load() {
      setIsLoading(true)
      await refreshThreads()
      if (mounted) {
        setIsLoading(false)
      }
    }
    void load()
    return () => {
      mounted = false
    }
  }, [refreshThreads])

  const createNewThread = useCallback(async (title?: string) => {
    const thread = await createThread(title)
    await refreshThreads()
    return thread.id
  }, [refreshThreads])

  const deleteThread = useCallback(async (threadId: string) => {
    await deleteThreadRequest(threadId)
    setThreads((current) => current.filter((thread) => thread.id !== threadId))
  }, [])

  const value = useMemo(
    () => ({
      threads,
      isLoading,
      error,
      refreshThreads,
      createNewThread,
      deleteThread,
    }),
    [threads, isLoading, error, refreshThreads, createNewThread, deleteThread],
  )

  return <ThreadsContext.Provider value={value}>{children}</ThreadsContext.Provider>
}
INNER_EOF

cat << 'INNER_EOF' > frontend/src/hooks/useThreads.ts
import { useContext } from 'react'
import { ThreadsContext } from '@/contexts/threads-context'

export function useThreads() {
  const context = useContext(ThreadsContext)
  if (!context) {
    throw new Error('useThreads must be used within ThreadsProvider')
  }
  return context
}
INNER_EOF

# 5. Create mobile and transport hooks
cat << 'INNER_EOF' > frontend/src/hooks/use-mobile.ts
import * as React from "react"

const MOBILE_BREAKPOINT = 768

export function useIsMobile() {
  const [isMobile, setIsMobile] = React.useState(
    () => window.innerWidth < MOBILE_BREAKPOINT
  )

  React.useEffect(() => {
    const mql = window.matchMedia(`(max-width: ${MOBILE_BREAKPOINT - 1}px)`)
    const onChange = () => {
      setIsMobile(window.innerWidth < MOBILE_BREAKPOINT)
    }
    mql.addEventListener("change", onChange)
    return () => mql.removeEventListener("change", onChange)
  }, [])

  return isMobile
}
INNER_EOF

cat << 'INNER_EOF' > frontend/src/hooks/useChatTransport.ts
import { useMemo } from 'react'
import { DefaultChatTransport } from 'ai'
import { getAccessToken } from '@/lib/api'
import { isStatusPart, type PipelineStatus } from '@/lib/citations'
import { env } from '@/lib/env'

async function consumeStatusStream(
  stream: ReadableStream<Uint8Array>,
  onStatus: (status: PipelineStatus) => void,
) {
  const reader = stream.getReader()
  const decoder = new TextDecoder()
  let buffer = ''

  try {
    while (true) {
      const { done, value } = await reader.read()
      if (done) {
        break
      }

      buffer += decoder.decode(value, { stream: true })
      const lines = buffer.split('\n')
      buffer = lines.pop() ?? ''

      for (const line of lines) {
        if (!line.startsWith('data: ')) {
          continue
        }

        try {
          const parsed: unknown = JSON.parse(line.slice(6))
          if (isStatusPart(parsed)) {
            onStatus(parsed.data)
          }
        } catch {
          // Ignore parse-errors from raw stream segments
        }
      }
    }
  } finally {
    reader.releaseLock()
  }
}

export function useChatTransport(
  threadId: string,
  onStatus?: (status: PipelineStatus) => void,
) {
  return useMemo(
    () =>
      new DefaultChatTransport({
        api: `${env.apiBaseUrl}/chat/stream`,
        headers: async (): Promise<Record<string, string>> => {
          const token = await getAccessToken()
          return token ? { Authorization: `Bearer ${token}` } : {}
        },
        prepareSendMessagesRequest: ({ messages }) => ({
          body: { threadId, messages },
        }),
        fetch: async (input, init) => {
          const response = await fetch(input, init)

          if (!response.ok || !response.body || !onStatus) {
            return response
          }

          const [clientStream, statusStream] = response.body.tee()
          void consumeStatusStream(statusStream, onStatus)

          return new Response(clientStream, {
            status: response.status,
            statusText: response.statusText,
            headers: response.headers,
          })
        },
      }),
    [threadId, onStatus],
  )
}
INNER_EOF

# 6. Create interface components
cat << 'INNER_EOF' > frontend/src/components/chat/PipelineStatus.tsx
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
INNER_EOF

cat << 'INNER_EOF' > frontend/src/components/chat/ChatInput.tsx
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
INNER_EOF

cat << 'INNER_EOF' > frontend/src/components/chat/MessageBubble.tsx
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
INNER_EOF

cat << 'INNER_EOF' > frontend/src/components/chat/MessageList.tsx
import type { ChatStatus, UIMessage } from 'ai'
import { StickToBottom } from 'use-stick-to-bottom'
import { MessageBubble } from '@/components/chat/MessageBubble'
import { PipelineStatus } from '@/components/chat/PipelineStatus'
import { textFromMessage, type PipelineStatus as PipelineStatusState } from '@/lib/citations'

type MessageListProps = {
  messages: UIMessage[]
  status: ChatStatus
  pipelineStatus: PipelineStatusState | null
  onSendSuggestion: (text: string) => void
}

const EXAMPLE_QUESTIONS = [
  "Across Apple's 2021–2025 10-Ks, how did the revenue mix between iPhone, Services, Mac, iPad, and Wearables change?",
  "For Amazon, compare AWS operating income and margin against North America and International from 2021–2025.",
  "How did NVIDIA describe demand drivers, customer concentration, and supply constraints for its Data Center business?",
  "Across Microsoft filings, what changed in how the company describes Azure, AI infrastructure, and cloud capacity constraints?",
] as const

export function MessageList({
  messages,
  status,
  pipelineStatus,
  onSendSuggestion,
}: MessageListProps) {
  const isBusy = status === 'submitted' || status === 'streaming'
  const text = messages.length > 0 ? textFromMessage(messages[messages.length - 1]) : ''
  const showPipeline = isBusy && !text

  return (
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
            <div className="grid grid-cols-1 md:grid-cols-2 gap-2 max-w-xl w-full">
              {EXAMPLE_QUESTIONS.map((question) => (
                <button
                  key={question}
                  type="button"
                  className="rounded-xl border border-input p-3 text-left text-xs transition-colors hover:bg-muted text-muted-foreground leading-normal"
                  onClick={() => onSendSuggestion(question)}
                >
                  {question}
                </button>
              ))}
            </div>
          </div>
        ) : null}

        {messages.map((message) => (
          <MessageBubble key={message.id} message={message} />
        ))}

        {showPipeline ? (
          <PipelineStatus
            isSubmitted={status === 'submitted'}
            pipelineStatus={pipelineStatus}
          />
        ) : null}
      </StickToBottom.Content>
    </StickToBottom>
  )
}
INNER_EOF

cat << 'INNER_EOF' > frontend/src/components/chat/UserMenu.tsx
import { useNavigate } from 'react-router-dom'
import { ChevronsUpDown, LogOut } from 'lucide-react'
import { Avatar, AvatarFallback } from '@/components/ui/avatar'
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu'
import { useSession } from '@/hooks/useSession'
import { supabase } from '@/lib/supabase'

export function UserMenu() {
  const navigate = useNavigate()
  const session = useSession()
  const email = session?.user?.email ?? 'Account'

  async function handleSignOut() {
    await supabase.auth.signOut()
    navigate('/login', { replace: true })
  }

  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <button className="flex w-full items-center gap-2 rounded-md p-2 text-left text-sm hover:bg-sidebar-accent hover:text-sidebar-accent-foreground">
          <Avatar className="h-6 w-6">
            <AvatarFallback className="text-[10px] bg-foreground text-background">
              {email.slice(0, 2).toUpperCase()}
            </AvatarFallback>
          </Avatar>
          <span className="truncate flex-1 font-medium">{email}</span>
          <ChevronsUpDown className="h-4 w-4 text-muted-foreground shrink-0" />
        </button>
      </DropdownMenuTrigger>
      <DropdownMenuContent className="w-56" align="end">
        <DropdownMenuLabel className="truncate font-normal text-muted-foreground">
          {email}
        </DropdownMenuLabel>
        <DropdownMenuSeparator />
        <DropdownMenuItem onClick={() => void handleSignOut()}>
          <LogOut className="mr-2 h-4 w-4" />
          Sign out
        </DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  )
}
INNER_EOF

cat << 'INNER_EOF' > frontend/src/components/chat/ThreadSidebar.tsx
import { useState } from 'react'
import { Link, useNavigate, useParams } from 'react-router-dom'
import { Plus, Trash2 } from 'lucide-react'
import { toast } from 'sonner'
import { Logo } from '@/components/Logo'
import { UserMenu } from '@/components/chat/UserMenu'
import { Button } from '@/components/ui/button'
import {
  Sidebar,
  SidebarContent,
  SidebarFooter,
  SidebarGroup,
  SidebarGroupContent,
  SidebarGroupLabel,
  SidebarHeader,
  SidebarMenu,
  SidebarMenuAction,
  SidebarMenuButton,
  SidebarMenuItem,
  useSidebar,
} from '@/components/ui/sidebar'
import { useThreads } from '@/hooks/useThreads'
import { groupByRecency } from '@/lib/format'

export function ThreadSidebar() {
  const navigate = useNavigate()
  const { threadId } = useParams()
  const { setOpenMobile, isMobile } = useSidebar()
  const { threads, isLoading, createNewThread, deleteThread } = useThreads()
  const [isCreating, setIsCreating] = useState(false)

  const groups = groupByRecency(threads, (thread) => thread.updatedAt)

  async function handleNewChat() {
    setIsCreating(true)
    try {
      const id = await createNewThread()
      navigate(`/chats/${id}`)
      if (isMobile) setOpenMobile(false)
    } finally {
      setIsCreating(false)
    }
  }

  async function handleDeleteThread(id: string) {
    try {
      await deleteThread(id)
      toast.success('Conversation deleted')
      if (id === threadId) {
        navigate('/chats', { replace: true })
      }
    } catch {
      toast.error('Could not delete conversation.')
    }
  }

  return (
    <Sidebar>
      <SidebarHeader className="gap-3 p-3">
        <Logo className="px-1 py-1" />
        <Button
          variant="outline"
          className="w-full justify-start gap-2 border-dashed bg-background/50 text-muted-foreground hover:bg-muted/50"
          onClick={() => void handleNewChat()}
          disabled={isCreating}
        >
          <Plus className="h-4 w-4" />
          {isCreating ? 'Creating…' : 'New chat'}
        </Button>
      </SidebarHeader>

      <SidebarContent className="px-1">
        {isLoading ? (
          <div className="p-4 text-xs text-muted-foreground">Loading chats...</div>
        ) : null}

        {!isLoading && threads.length === 0 ? (
          <p className="px-3 py-2 text-xs text-muted-foreground">No conversations yet.</p>
        ) : null}

        {!isLoading &&
          groups.map((group) => (
            <SidebarGroup key={group.label}>
              <SidebarGroupLabel>{group.label}</SidebarGroupLabel>
              <SidebarGroupContent>
                <SidebarMenu>
                  {group.items.map((thread) => (
                    <SidebarMenuItem key={thread.id}>
                      <SidebarMenuButton
                        isActive={thread.id === threadId}
                        onClick={() => {
                          navigate(`/chats/${thread.id}`)
                          if (isMobile) setOpenMobile(false)
                        }}
                        className="pr-8"
                      >
                        <span className="truncate">{thread.title}</span>
                      </SidebarMenuButton>
                      <SidebarMenuAction
                        showOnHover
                        aria-label={`Delete conversation: ${thread.title}`}
                        title="Delete conversation"
                        className="text-muted-foreground hover:bg-destructive/10 hover:text-destructive"
                        onClick={(e) => {
                          e.stopPropagation()
                          void handleDeleteThread(thread.id)
                        }}
                      >
                        <Trash2 className="h-3.5 w-3.5" />
                      </SidebarMenuAction>
                    </SidebarMenuItem>
                  ))}
                </SidebarMenu>
              </SidebarGroupContent>
            </SidebarGroup>
          ))}
      </SidebarContent>

      <SidebarFooter>
        <UserMenu />
      </SidebarFooter>
    </Sidebar>
  )
}
INNER_EOF

cat << 'INNER_EOF' > frontend/src/components/chat/ChatLayout.tsx
import { Outlet, useParams } from 'react-router-dom'
import { ThreadSidebar } from '@/components/chat/ThreadSidebar'
import { ThreadsProvider } from '@/components/chat/ThreadsProvider'
import {
  SidebarInset,
  SidebarProvider,
  SidebarTrigger,
} from '@/components/ui/sidebar'
import { useThreads } from '@/hooks/useThreads'

function ChatHeader() {
  const { threadId } = useParams()
  const { threads } = useThreads()
  const activeThread = threads.find((thread) => thread.id === threadId)

  return (
    <header className="flex h-14 shrink-0 items-center gap-2 border-b bg-background/80 px-3 backdrop-blur">
      <SidebarTrigger className="text-muted-foreground" />
      <span className="truncate text-sm font-medium text-foreground">
        {activeThread?.title ?? 'Document Copilot'}
      </span>
    </header>
  )
}

function ChatLayoutContent() {
  return (
    <SidebarProvider>
      <ThreadSidebar />
      <SidebarInset className="flex h-svh min-h-0 flex-col">
        <ChatHeader />
        <div className="flex min-h-0 flex-1 flex-col">
          <Outlet />
        </div>
      </SidebarInset>
    </SidebarProvider>
  )
}

export function ChatLayout() {
  return (
    <ThreadsProvider>
      <ChatLayoutContent />
    </ThreadsProvider>
  )
}
INNER_EOF

# 7. Create views & workspaces
cat << 'INNER_EOF' > frontend/src/pages/chat/ChatEmptyPage.tsx
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
        {EXAMPLE_QUESTIONS_PLACEHOLDER.map((question) => (
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
INNER_EOF

# Quick fix on ChatEmptyPage replacement logic (correct placeholder variables)
sed -i 's/EXAMPLE_QUESTIONS_PLACEHOLDER/EXAMPLE_QUESTIONS/g' frontend/src/pages/chat/ChatEmptyPage.tsx
sed -i 's/handleStart/handleStart/g' frontend/src/pages/chat/ChatEmptyPage.tsx

cat << 'INNER_EOF' > frontend/src/pages/chat/ChatThreadPage.tsx
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
INNER_EOF

# 8. Update routing structure inside App.tsx
cat << 'INNER_EOF' > frontend/src/App.tsx
import { BrowserRouter, Navigate, Route, Routes } from 'react-router-dom'
import { ProtectedRoute } from '@/components/ProtectedRoute'
import { PublicRoute } from '@/components/PublicRoute'
import { Login } from '@/pages/Login'
import { SignUp } from '@/pages/SignUp'
import { ChatLayout } from '@/components/chat/ChatLayout'
import { ChatEmptyPage } from '@/pages/chat/ChatEmptyPage'
import { ChatThreadPage } from '@/pages/chat/ChatThreadPage'

function App() {
  return (
    <BrowserRouter>
      <Routes>
        <Route
          path="/login"
          element={
            <PublicRoute>
              <Login />
            </PublicRoute>
          }
        />
        <Route
          path="/signup"
          element={
            <PublicRoute>
              <SignUp />
            </PublicRoute>
          }
        />
        <Route
          path="/chats"
          element={
            <ProtectedRoute>
              <ChatLayout />
            </ProtectedRoute>
          }
        >
          <Route index element={<ChatEmptyPage />} />
          <Route path=":threadId" element={<ChatThreadPage />} />
        </Route>
        <Route path="*" element={<Navigate to="/chats" replace />} />
      </Routes>
    </BrowserRouter>
  )
}

export default App
INNER_EOF

echo "Frontend Chat Shell setup complete! Clean up script."
rm setup_frontend_chat_shell.sh
EOF

# Run the script to generate all frontend files
bash setup_frontend_chat_shell.sh