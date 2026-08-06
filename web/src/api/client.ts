import type {
  OverviewResponse,
  EntriesResponse,
  ProvidersResponse,
  SnapshotsResponse,
  RouteConfig,
  LoginResponse,
  TestResult,
  GatewayKeyConfig,
  OAuthStartResult,
  OAuthPollResult,
} from './types'

const BASE = ''

function getToken(): string | null {
  return localStorage.getItem('admin_token')
}

function setToken(token: string) {
  localStorage.setItem('admin_token', token)
}

function clearToken() {
  localStorage.removeItem('admin_token')
}

async function request<T>(path: string, options: RequestInit = {}): Promise<T> {
  const token = getToken()
  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
    ...(options.headers as Record<string, string>),
  }
  if (token) {
    headers['Authorization'] = `Bearer ${token}`
  }
  const res = await fetch(`${BASE}${path}`, { ...options, headers })
  if (res.status === 401 && !path.includes('/login')) {
    clearToken()
    window.location.reload()
    throw new Error('Unauthorized')
  }
  const payload = await res.json().catch(() => null)
  if (!res.ok) {
    const message = typeof payload?.error === 'string'
      ? payload.error
      : payload?.error?.message ?? `请求失败（HTTP ${res.status}）`
    throw new Error(message)
  }
  return payload as T
}

export const api = {
  async login(password: string): Promise<string | null> {
    const res = await fetch(`${BASE}/admin/api/login`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ password }),
    })
    if (!res.ok) return null
    const data: LoginResponse = await res.json()
    setToken(data.token)
    return data.token
  },

  async overview(): Promise<OverviewResponse> {
    return request('/admin/api/overview')
  },

  async entries(limit = 50): Promise<EntriesResponse> {
    return request(`/admin/api/entries?limit=${limit}`)
  },

  async providers(): Promise<ProvidersResponse> {
    return request('/admin/api/providers')
  },

  async snapshots(): Promise<SnapshotsResponse> {
    return request('/admin/api/snapshots')
  },

  async getConfig(): Promise<RouteConfig> {
    return request('/admin/api/config')
  },

  async saveConfig(config: RouteConfig): Promise<{ status: string }> {
    return request('/admin/api/config', {
      method: 'POST',
      body: JSON.stringify(config),
    })
  },

  async refreshUsage(): Promise<SnapshotsResponse> {
    return request('/admin/api/usage/refresh', { method: 'POST' })
  },

  async testProvider(providerID: string): Promise<TestResult> {
    return request(`/admin/api/providers/${providerID}/test`, { method: 'POST' })
  },

  async createKey(key?: string, enabledModels?: string[]): Promise<GatewayKeyConfig> {
    return request('/admin/api/keys', {
      method: 'POST',
      body: JSON.stringify({ key, enabledModels }),
    })
  },

  async deleteKey(key: string): Promise<{ status: string }> {
    return request(`/admin/api/keys/${key}`, { method: 'DELETE' })
  },

  async testModel(providerID: string, model: string, message?: string): Promise<TestResult> {
    return request(`/admin/api/providers/${providerID}/test-model`, {
      method: 'POST',
      body: JSON.stringify({ model, message }),
    })
  },

  async oauthStart(providerID: string): Promise<OAuthStartResult> {
    return request(`/admin/api/providers/${providerID}/oauth/start`, { method: 'POST' })
  },

  async oauthPoll(providerID: string): Promise<OAuthPollResult> {
    return request(`/admin/api/providers/${providerID}/oauth/poll`, { method: 'POST' })
  },

  async playgroundStream(
    model: string,
    message: string,
    onChunk: (text: string) => void,
    signal?: AbortSignal,
  ): Promise<{ tokens: { promptTokens: number; completionTokens: number; totalTokens: number } | null }> {
    const token = getToken()
    const headers: Record<string, string> = { 'Content-Type': 'application/json' }
    if (token) headers['Authorization'] = `Bearer ${token}`
    const res = await fetch(`${BASE}/admin/api/playground`, {
      method: 'POST',
      headers,
      body: JSON.stringify({ model, message, stream: true }),
      signal,
    })
    if (!res.ok || !res.body) {
      const payload = await res.json().catch(() => null)
      throw new Error(payload?.error ?? `请求失败（HTTP ${res.status}）`)
    }
    const reader = res.body.getReader()
    const decoder = new TextDecoder()
    let buffer = ''
    let tokens: { promptTokens: number; completionTokens: number; totalTokens: number } | null = null
    while (true) {
      const { done, value } = await reader.read()
      if (done) break
      buffer += decoder.decode(value, { stream: true })
      const lines = buffer.split('\n')
      buffer = lines.pop() ?? ''
      for (const line of lines) {
        const trimmed = line.trim()
        if (!trimmed.startsWith('data:')) continue
        const data = trimmed.slice(5).trim()
        if (data === '[DONE]') continue
        try {
          const json = JSON.parse(data)
          const content = json?.choices?.[0]?.delta?.content
          if (typeof content === 'string' && content) onChunk(content)
          if (json?.usage) {
            tokens = {
              promptTokens: json.usage.prompt_tokens ?? 0,
              completionTokens: json.usage.completion_tokens ?? 0,
              totalTokens: json.usage.total_tokens ?? 0,
            }
          }
        } catch {
          // 忽略非 JSON 行
        }
      }
    }
    return { tokens }
  },

  getToken,
  clearToken,
  isLoggedIn(): boolean {
    return !!getToken()
  },
}
