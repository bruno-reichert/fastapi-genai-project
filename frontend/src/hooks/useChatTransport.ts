import { useMemo } from 'react'
import { DefaultChatTransport } from 'ai'
import { getAccessToken } from '@/lib/api'
import { env } from '@/lib/env'

export function useChatTransport(
  threadId: string,
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
          return fetch(input, init)
        },
      }),
    [threadId],
  )
}