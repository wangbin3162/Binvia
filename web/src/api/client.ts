import type {
  OverviewResponse,
  EntriesResponse,
  ProvidersResponse,
  SnapshotsResponse,
  RouteConfig,
  LoginResponse,
  TestResult,
  GatewayKeyConfig,
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

  getToken,
  clearToken,
  isLoggedIn(): boolean {
    return !!getToken()
  },
}
