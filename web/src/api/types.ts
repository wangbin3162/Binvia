export interface ProviderHealth {
  id: string
  displayName: string
  configured: boolean
  enabled: boolean
}

export interface ServerInfo {
  running: boolean
  host: string
  port: number
}

export interface Summary {
  totalRequests: number
  totalErrors: number
  activeProviders: number
  promptTokens: number
  completionTokens: number
  totalTokens: number
}

export interface OverviewResponse {
  server: ServerInfo
  summary: Summary
  providers: ProviderHealth[]
}

export interface RequestLogEntry {
  id: string
  timestamp: string
  method: string
  path: string
  providerID: string | null
  model: string | null
  statusCode: number
  durationMS: number
  error: string | null
  tokens: { promptTokens: number; completionTokens: number; totalTokens: number } | null
}

export interface EntriesResponse {
  entries: RequestLogEntry[]
}

export interface ProviderItem {
  id: string
  alias: string | null
  displayName: string
  authType: string
  configured: boolean
  enabled: boolean
  region: string | null
  modelCount: number
  models: string[]
  baseURL: string | null
  isUserDefined: boolean
}

export interface ProvidersResponse {
  providers: ProviderItem[]
}

export interface KeyedBalance {
  label: string
  balance: number
  currency: string | null
}

export interface QuotaWindow {
  label: string
  remainingRatio: number
  remainingFraction: number
  remainingPercentage: number
  resetAt: string | null
  resetsAt: string | null
  unlimited: boolean
  used: number
  total: number
}

export interface ModelQuota {
  modelId: string
  remainingFraction: number
  remainingPercentage: number
  resetAt: string | null
  unlimited: boolean
}

export interface ProviderUsageSnapshot {
  providerID: string
  balance: number | null
  currency: string | null
  balances: KeyedBalance[]
  quotaWindows: QuotaWindow[]
  modelQuotas: ModelQuota[]
  rawJSON: string | null
  fetchedAt: string
  error: string | null
}

export interface SnapshotsResponse {
  snapshots: Record<string, ProviderUsageSnapshot>
}

export interface GatewayKeyConfig {
  key: string
  enabledModels: string[] | null
}

export interface RouteConfig {
  version: number
  host: string
  port: number
  apiKeys: GatewayKeyConfig[]
  providers: Record<string, ProviderConfig>
  providerOrder: string[]
  customProviderDefs: CustomProviderDef[]
  webPanelEnabled: boolean
  adminPassword: string | null
}

export interface CustomProviderDef {
  id: string
  displayName: string
  baseURL: string
  models: string[]
}

export interface ProviderCredential {
  apiKey: string | null
  accessToken: string | null
  refreshToken: string | null
  email: string | null
  region: string | null
  machineId?: string | null
  workspaceId?: string | null
}

export interface ProviderConfig {
  enabled: boolean
  credential: ProviderCredential
  apiKeys: { label: string; value: string }[]
  region: string | null
  disabledModels: string[]
}

export interface LoginResponse {
  token: string
}

export interface TestResult {
  success: boolean
  message: string
  latencyMs?: number
}

export interface OAuthStartResult {
  providerID: string
  authUrl: string
  state?: string
  interval?: number
  expiresIn?: number
  redirectUri?: string
}

export interface OAuthCredentialResult {
  accessToken: string | null
  refreshToken: string | null
  email: string | null
  expiresAt: string | null
}

export interface OAuthPollResult {
  status: 'pending' | 'ok' | 'error'
  message?: string
  credential?: OAuthCredentialResult
}
