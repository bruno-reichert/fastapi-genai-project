import { supabase } from '@/lib/supabase'
import { Button } from '@/components/ui/button'

export function ChatsWorkspace() {
  const handleLogout = async () => {
    await supabase.auth.signOut()
  }

  return (
    <div className="flex h-screen flex-col items-center justify-center gap-4">
      <h1 className="text-2xl font-bold">Document Copilot Workspace</h1>
      <p className="text-muted-foreground text-sm">Authenticated successfully.</p>
      <Button variant="destructive" onClick={handleLogout}>
        Sign out
      </Button>
    </div>
  )
}
