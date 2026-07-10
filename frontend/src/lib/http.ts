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
