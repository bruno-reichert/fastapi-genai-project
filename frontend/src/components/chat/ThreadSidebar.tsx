import { useState } from 'react'
import { useNavigate, useParams } from 'react-router-dom'
import { Plus, Trash2 } from 'lucide-react'
import { toast } from 'sonner'
import { LogoMark } from '@/components/Logo'
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
import { cn } from '@/lib/utils'

export function ThreadSidebar() {
  const navigate = useNavigate()
  const { threadId } = useParams()
  const { setOpenMobile, isMobile, state } = useSidebar()
  const { threads, isLoading, createNewThread, deleteThread } = useThreads()
  const [isCreating, setIsCreating] = useState(false)

  const isCollapsed = state === "collapsed"
  const groups = groupByRecency(threads, (thread: any) => thread.updatedAt)

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
      <SidebarHeader className={cn("gap-3", isCollapsed ? "p-2 items-center" : "p-3")}>
        {isCollapsed ? (
          <LogoMark className="size-8" />
        ) : (
          <div className="flex flex-col leading-none py-1">
            <span className="text-sm font-semibold tracking-tight">Document Copilot</span>
            <span className="text-[10px] text-muted-foreground mt-0.5">SEC filing assistant</span>
          </div>
        )}

        <Button
          variant="outline"
          className={cn(
            "border-dashed bg-background/50 text-muted-foreground hover:bg-muted/50 transition-all duration-200",
            isCollapsed ? "h-8 w-8 rounded-md p-0 justify-center" : "w-full justify-start gap-2"
          )}
          onClick={() => void handleNewChat()}
          disabled={isCreating}
          title={isCollapsed ? "New Chat" : undefined}
        >
          <Plus className="h-4 w-4 shrink-0" />
          {!isCollapsed && (isCreating ? 'Creating…' : 'New chat')}
        </Button>
      </SidebarHeader>

      <SidebarContent className="px-1">
        {isLoading && !isCollapsed ? (
          <div className="p-4 text-xs text-muted-foreground">Loading chats...</div>
        ) : null}

        {!isLoading && threads.length === 0 && !isCollapsed ? (
          <p className="px-3 py-2 text-xs text-muted-foreground text-center">No conversations yet.</p>
        ) : null}

        {!isLoading &&
          groups.map((group: any) => (
            <SidebarGroup key={group.label}>
              <SidebarGroupLabel>{group.label}</SidebarGroupLabel>
              <SidebarGroupContent>
                <SidebarMenu>
                  {group.items.map((thread: any) => (
                    <SidebarMenuItem key={thread.id}>
                      <SidebarMenuButton
                        isActive={thread.id === threadId}
                        onClick={() => {
                          navigate(`/chats/${thread.id}`)
                          if (isMobile) setOpenMobile(false)
                        }}
                        className={isCollapsed ? "justify-center p-0" : "pr-8"}
                      >
                        {isCollapsed ? (
                          <span className="text-[10px] font-bold text-center uppercase tabular-nums select-none shrink-0 w-8 h-8 flex items-center justify-center border border-border bg-background rounded-md">
                            {thread.title.slice(0, 2)}
                          </span>
                        ) : (
                          <span className="truncate">{thread.title}</span>
                        )}
                      </SidebarMenuButton>
                      {!isCollapsed && (
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
                      )}
                    </SidebarMenuItem>
                  ))}
                </SidebarMenu>
              </SidebarGroupContent>
            </SidebarGroup>
          ))}
      </SidebarContent>

      <SidebarFooter className="p-1.5 overflow-hidden shrink-0">
        <UserMenu />
      </SidebarFooter>
    </Sidebar>
  )
}