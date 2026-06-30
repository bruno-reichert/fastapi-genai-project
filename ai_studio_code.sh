# Execute from your repository root
cat << 'EOF' > setup_frontend_auth.sh
#!/bin/bash
set -e

# Create directories
mkdir -p frontend/src/lib
mkdir -p frontend/src/hooks
mkdir -p frontend/src/components/ui
mkdir -p frontend/src/pages

# 1. Create Tailwind Utility
cat << 'INNER_EOF' > frontend/src/lib/utils.ts
import { clsx, type ClassValue } from "clsx"
import { twMerge } from "tailwind-merge"

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs))
}
INNER_EOF

# 2. Create Environment Settings
cat << 'INNER_EOF' > frontend/src/lib/env.ts
function requireEnv(name: keyof ImportMetaEnv): string {
  const value = import.meta.env[name]
  if (typeof value !== 'string' || value.trim() === '') {
    throw new Error(`Missing required environment variable: ${name}`)
  }
  return value.trim()
}

export const env = {
  apiBaseUrl: requireEnv('VITE_API_BASE_URL').replace(/\/$/, ''),
  supabaseUrl: requireEnv('VITE_SUPABASE_URL'),
  supabaseAnonKey: requireEnv('VITE_SUPABASE_ANON_KEY'),
} as const
INNER_EOF

# 3. Create Supabase Client
cat << 'INNER_EOF' > frontend/src/lib/supabase.ts
import { createClient } from '@supabase/supabase-js'
import { env } from '@/lib/env'

export const supabase = createClient(env.supabaseUrl, env.supabaseAnonKey)
INNER_EOF

# 4. Create HTTP Client
cat << 'INNER_EOF' > frontend/src/lib/http.ts
import { env } from '@/lib/env'

const DEFAULT_TIMEOUT_MS = 30_000

type HttpMethod = 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE'

export type RequestOptions = {
  method?: HttpMethod
  body?: unknown
  headers?: Record<string, string>
  accessToken?: string | null
  timeoutMs?: number
}

export class ApiError extends Error {
  readonly status: number
  readonly detail: unknown
  readonly isNetworkError: boolean

  constructor(
    message: string,
    options: {
      status: number
      detail?: unknown
      isNetworkError?: boolean
    },
  ) {
    super(message)
    this.name = 'ApiError'
    this.status = options.status
    this.detail = options.detail
    this.isNetworkError = options.isNetworkError ?? false
  }
}

function buildUrl(path: string): string {
  return path.startsWith('/') ? `${env.apiBaseUrl}${path}` : `${env.apiBaseUrl}/${path}`
}

async function parseErrorBody(response: Response): Promise<unknown> {
  const contentType = response.headers.get('content-type') ?? ''
  if (contentType.includes('application/json')) {
    try {
      return await response.json()
    } catch {
      return null
    }
  }

  try {
    const text = await response.text()
    return text.length > 0 ? text : null
  } catch {
    return null
  }
}

function errorMessage(detail: unknown, fallback: string): string {
  if (typeof detail === 'string' && detail.trim() !== '') {
    return detail
  }

  if (
    detail !== null &&
    typeof detail === 'object' &&
    'detail' in detail &&
    typeof detail.detail === 'string'
  ) {
    return detail.detail
  }

  return fallback
}

export async function request<T>(path: string, options: RequestOptions = {}): Promise<T> {
  const {
    method = 'GET',
    body,
    headers = {},
    accessToken,
    timeoutMs = DEFAULT_TIMEOUT_MS,
  } = options

  const requestHeaders = new Headers(headers)

  if (accessToken) {
    requestHeaders.set('Authorization', `Bearer ${accessToken}`)
  }

  const controller = new AbortController()
  const timeoutId = setTimeout(() => controller.abort(), timeoutMs)

  try {
    const response = await fetch(buildUrl(path), {
      method,
      headers: requestHeaders,
      body: body ? JSON.stringify(body) : undefined,
      signal: controller.signal,
    })

    clearTimeout(timeoutId)

    if (!response.ok) {
      const errorDetail = await parseErrorBody(response)
      throw new ApiError(errorMessage(errorDetail, response.statusText), {
        status: response.status,
        detail: errorDetail,
      })
    }

    if (response.status === 204) {
      return null as T
    }

    return (await response.json()) as T
  } catch (err) {
    clearTimeout(timeoutId)
    if (err instanceof ApiError) {
      throw err
    }
    const isAbort = err instanceof DOMException && err.name === 'AbortError'
    throw new ApiError(isAbort ? 'Request timed out' : 'Network connection failure', {
      status: 0,
      isNetworkError: true,
    })
  }
}
INNER_EOF

# 5. Create API Auth Wrapper
cat << 'INNER_EOF' > frontend/src/lib/api.ts
import { request, type RequestOptions } from '@/lib/http'
import { supabase } from '@/lib/supabase'

export async function getAccessToken(): Promise<string | null> {
  const { data } = await supabase.auth.getSession()
  return data.session?.access_token ?? null
}

async function withAuth<T>(
  path: string,
  options: Omit<RequestOptions, 'accessToken'> = {},
): Promise<T> {
  return request<T>(path, {
    ...options,
    accessToken: await getAccessToken(),
  })
}

export const api = {
  get: <T>(path: string, options?: Omit<RequestOptions, 'accessToken' | 'method' | 'body'>) =>
    withAuth<T>(path, { ...options, method: 'GET' }),

  post: <T>(
    path: string,
    body?: unknown,
    options?: Omit<RequestOptions, 'accessToken' | 'method' | 'body'>,
  ) => withAuth<T>(path, { ...options, method: 'POST', body }),

  put: <T>(
    path: string,
    body?: unknown,
    options?: Omit<RequestOptions, 'accessToken' | 'method' | 'body'>,
  ) => withAuth<T>(path, { ...options, method: 'PUT', body }),

  patch: <T>(
    path: string,
    body?: unknown,
    options?: Omit<RequestOptions, 'accessToken' | 'method' | 'body'>,
  ) => withAuth<T>(path, { ...options, method: 'PATCH', body }),

  delete: <T>(path: string, options?: Omit<RequestOptions, 'accessToken' | 'method' | 'body'>) =>
    withAuth<T>(path, { ...options, method: 'DELETE' }),
}
INNER_EOF

# 6. Create Session Hook
cat << 'INNER_EOF' > frontend/src/hooks/useSession.ts
import { useEffect, useState } from 'react'
import type { Session } from '@supabase/supabase-js'
import { supabase } from '@/lib/supabase'

export function useSession(): Session | null | undefined {
  const [session, setSession] = useState<Session | null | undefined>(undefined)

  useEffect(() => {
    let mounted = true

    supabase.auth.getSession().then(({ data: { session } }) => {
      if (mounted) {
        setSession(session)
      }
    })

    const {
      data: { subscription },
    } = supabase.auth.onAuthStateChange((_event, session) => {
      if (mounted) {
        setSession(session)
      }
    })

    return () => {
      mounted = false
      subscription.unsubscribe()
    }
  }, [])

  return session
}
INNER_EOF

# 7. Create Navigation Route Guards
cat << 'INNER_EOF' > frontend/src/components/ProtectedRoute.tsx
import type { ReactNode } from 'react'
import { Navigate } from 'react-router-dom'
import { useSession } from '@/hooks/useSession'

type ProtectedRouteProps = {
  children: ReactNode
}

export function ProtectedRoute({ children }: ProtectedRouteProps) {
  const session = useSession()

  if (session === undefined) {
    return (
      <div className="flex min-h-screen items-center justify-center text-sm text-muted-foreground">
        Loading session…
      </div>
    )
  }

  if (!session) {
    return <Navigate to="/login" replace />
  }

  return children
}
INNER_EOF

cat << 'INNER_EOF' > frontend/src/components/PublicRoute.tsx
import type { ReactNode } from 'react'
import { Navigate } from 'react-router-dom'
import { useSession } from '@/hooks/useSession'

type PublicRouteProps = {
  children: ReactNode
}

export function PublicRoute({ children }: PublicRouteProps) {
  const session = useSession()

  if (session === undefined) {
    return (
      <div className="flex min-h-screen items-center justify-center text-sm text-muted-foreground">
        Loading session…
      </div>
    )
  }

  if (session) {
    return <Navigate to="/chats" replace />
  }

  return children
}
INNER_EOF

# 8. Create Card UI Primitives
cat << 'INNER_EOF' > frontend/src/components/ui/card.tsx
import * as React from "react"
import { cn } from "@/lib/utils"

function Card({
  className,
  ...props
}: React.ComponentProps<"div">) {
  return (
    <div
      data-slot="card"
      className={cn(
        "rounded-xl border bg-card text-card-foreground shadow-sm py-4 px-6 flex flex-col gap-4 overflow-hidden",
        className
      )}
      {...props}
    />
  )
}

function CardHeader({ className, ...props }: React.ComponentProps<"div">) {
  return (
    <div
      data-slot="card-header"
      className={cn("flex flex-col space-y-1.5", className)}
      {...props}
    />
  )
}

function CardTitle({ className, ...props }: React.ComponentProps<"div">) {
  return (
    <div
      data-slot="card-title"
      className={cn("font-semibold leading-none tracking-tight", className)}
      {...props}
    />
  )
}

function CardDescription({ className, ...props }: React.ComponentProps<"div">) {
  return (
    <div
      data-slot="card-description"
      className={cn("text-sm text-muted-foreground", className)}
      {...props}
    />
  )
}

function CardContent({ className, ...props }: React.ComponentProps<"div">) {
  return (
    <div
      data-slot="card-content"
      className={cn("pt-0", className)}
      {...props}
    />
  )
}

export {
  Card,
  CardHeader,
  CardTitle,
  CardDescription,
  CardContent,
}
INNER_EOF

# 9. Create Input UI Primitives
cat << 'INNER_EOF' > frontend/src/components/ui/input.tsx
import * as React from "react"
import { cn } from "@/lib/utils"

function Input({ className, type, ...props }: React.ComponentProps<"input">) {
  return (
    <input
      type={type}
      data-slot="input"
      className={cn(
        "flex h-9 w-full rounded-md border border-input bg-transparent px-3 py-1 text-sm shadow-sm transition-colors file:border-0 file:bg-transparent file:text-sm file:font-medium placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring disabled:cursor-not-allowed disabled:opacity-50",
        className
      )}
      {...props}
    />
  )
}

export { Input }
INNER_EOF

# 10. Create Label UI Primitives
cat << 'INNER_EOF' > frontend/src/components/ui/label.tsx
import * as React from "react"
import * as LabelPrimitive from "@radix-ui/react-label"
import { cn } from "@/lib/utils"

function Label({
  className,
  ...props
}: React.ComponentProps<typeof LabelPrimitive.Root>) {
  return (
    <LabelPrimitive.Root
      data-slot="label"
      className={cn(
        "text-sm font-medium leading-none peer-disabled:cursor-not-allowed peer-disabled:opacity-70",
        className
      )}
      {...props}
    />
  )
}

export { Label }
INNER_EOF

# 11. Create Logo UI Component
cat << 'INNER_EOF' > frontend/src/components/Logo.tsx
import { cn } from '@/lib/utils'

type LogoProps = {
  className?: string
}

export function LogoMark({ className }: LogoProps) {
  return (
    <span
      className={cn(
        'flex size-8 shrink-0 items-center justify-center overflow-hidden rounded-lg bg-black p-1.5',
        className,
      )}
    >
      <div className="size-full bg-white rounded-sm" />
    </span>
  )
}

export function Logo({ className }: LogoProps) {
  return (
    <div className={cn('flex items-center gap-2.5', className)}>
      <LogoMark />
      <div className="flex flex-col leading-none">
        <span className="text-sm font-semibold tracking-tight text-foreground">
          Document Copilot
        </span>
        <span className="text-xs text-muted-foreground">SEC filing assistant</span>
      </div>
    </div>
  )
}
INNER_EOF

# 12. Create Auth Layout
cat << 'INNER_EOF' > frontend/src/components/AuthLayout.tsx
import type { ReactNode } from 'react'
import { Logo } from '@/components/Logo'
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from '@/components/ui/card'

type AuthLayoutProps = {
  title: string
  description?: string
  children: ReactNode
}

export function AuthLayout({ title, description, children }: AuthLayoutProps) {
  return (
    <div className="flex min-h-svh flex-col items-center justify-center gap-6 bg-muted/30 p-4">
      <Logo />
      <Card className="w-full max-w-sm">
        <CardHeader>
          <CardTitle className="text-xl">{title}</CardTitle>
          {description ? <CardDescription>{description}</CardDescription> : null}
        </CardHeader>
        <CardContent>{children}</CardContent>
      </Card>
    </div>
  )
}
INNER_EOF

# 13. Create Login Page
cat << 'INNER_EOF' > frontend/src/pages/Login.tsx
import { useState, type FormEvent } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { AuthLayout } from '@/components/AuthLayout'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { supabase } from '@/lib/supabase'

export function Login() {
  const navigate = useNavigate()
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [isSubmitting, setIsSubmitting] = useState(false)

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    setError(null)
    setIsSubmitting(true)

    const { error: signInError } = await supabase.auth.signInWithPassword({
      email: email.trim(),
      password,
    })

    setIsSubmitting(false)

    if (signInError) {
      setError(signInError.message)
      return
    }

    navigate('/chats', { replace: true })
  }

  return (
    <AuthLayout
      title="Sign in"
      description="Use your email and password to access Document Copilot."
    >
      <form className="space-y-4" onSubmit={handleSubmit}>
        <div className="space-y-2">
          <Label htmlFor="email">Email</Label>
          <Input
            id="email"
            type="email"
            autoComplete="email"
            required
            value={email}
            onChange={(event) => setEmail(event.target.value)}
            placeholder="you@driftwood.com"
          />
        </div>

        <div className="space-y-2">
          <Label htmlFor="password">Password</Label>
          <Input
            id="password"
            type="password"
            autoComplete="current-password"
            required
            value={password}
            onChange={(event) => setPassword(event.target.value)}
          />
        </div>

        {error ? (
          <p className="text-sm text-destructive" role="alert">
            {error}
          </p>
        ) : null}

        <Button type="submit" className="w-full" disabled={isSubmitting}>
          {isSubmitting ? 'Signing in…' : 'Sign in'}
        </Button>
      </form>

      <p className="mt-4 text-center text-sm text-muted-foreground">
        Need an account?{' '}
        <Link to="/signup" className="text-foreground underline underline-offset-4 hover:underline">
          Sign up
        </Link>
      </p>
    </AuthLayout>
  )
}
INNER_EOF

# 14. Create Signup Page
cat << 'INNER_EOF' > frontend/src/pages/SignUp.tsx
import { useState, type FormEvent } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { AuthLayout } from '@/components/AuthLayout'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { supabase } from '@/lib/supabase'

export function SignUp() {
  const navigate = useNavigate()
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [confirmPassword, setConfirmPassword] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [message, setMessage] = useState<string | null>(null)
  const [isSubmitting, setIsSubmitting] = useState(false)

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    setError(null)
    setMessage(null)

    if (password !== confirmPassword) {
      setError('Passwords do not match.')
      return
    }

    if (password.length < 6) {
      setError('Password must be at least 6 characters.')
      return
    }

    setIsSubmitting(true)

    const { data, error: signUpError } = await supabase.auth.signUp({
      email: email.trim(),
      password,
    })

    setIsSubmitting(false)

    if (signUpError) {
      setError(signUpError.message)
      return
    }

    if (data.session) {
      navigate('/chats', { replace: true })
      return
    }

    setMessage('Account created. Check your email to confirm your address, then sign in.')
  }

  return (
    <AuthLayout
      title="Create account"
      description="Sign up with your work email to use Document Copilot."
    >
      <form className="space-y-4" onSubmit={handleSubmit}>
        <div className="space-y-2">
          <Label htmlFor="email">Email</Label>
          <Input
            id="email"
            type="email"
            autoComplete="email"
            required
            value={email}
            onChange={(event) => setEmail(event.target.value)}
            placeholder="you@driftwood.com"
          />
        </div>

        <div className="space-y-2">
          <Label htmlFor="password">Password</Label>
          <Input
            id="password"
            type="password"
            autoComplete="new-password"
            required
            value={password}
            onChange={(event) => setPassword(event.target.value)}
          />
        </div>

        <div className="space-y-2">
          <Label htmlFor="confirm-password">Confirm password</Label>
          <Input
            id="confirm-password"
            type="password"
            autoComplete="new-password"
            required
            value={confirmPassword}
            onChange={(event) => setConfirmPassword(event.target.value)}
          />
        </div>

        {error ? (
          <p className="text-sm text-destructive" role="alert">
            {error}
          </p>
        ) : null}

        {message ? (
          <p className="text-sm text-muted-foreground" role="status">
            {message}
          </p>
        ) : null}

        <Button type="submit" className="w-full" disabled={isSubmitting}>
          {isSubmitting ? 'Creating account…' : 'Create account'}
        </Button>
      </form>

      <p className="mt-4 text-center text-sm text-muted-foreground">
        Already have an account?{' '}
        <Link to="/login" className="text-foreground underline underline-offset-4 hover:underline">
          Sign in
        </Link>
      </p>
    </AuthLayout>
  )
}
INNER_EOF

# 15. Create Workspace Placeholder (Chats Layout)
cat << 'INNER_EOF' > frontend/src/pages/ChatsWorkspace.tsx
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
INNER_EOF

# 16. Update App.tsx Routing Layout
cat << 'INNER_EOF' > frontend/src/App.tsx
import { BrowserRouter, Navigate, Route, Routes } from 'react-router-dom'
import { ProtectedRoute } from '@/components/ProtectedRoute'
import { PublicRoute } from '@/components/PublicRoute'
import { Login } from '@/pages/Login'
import { SignUp } from '@/pages/SignUp'
import { ChatsWorkspace } from '@/pages/ChatsWorkspace'

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
              <ChatsWorkspace />
            </ProtectedRoute>
          }
        />
        <Route path="*" element={<Navigate to="/chats" replace />} />
      </Routes>
    </BrowserRouter>
  )
}

export default App
INNER_EOF

echo "Boilerplate setup complete! Run cleanup."
rm setup_frontend_auth.sh
EOF

# Run the script to generate all files
bash setup_frontend_auth.sh