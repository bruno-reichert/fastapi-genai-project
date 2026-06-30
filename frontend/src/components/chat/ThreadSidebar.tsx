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
