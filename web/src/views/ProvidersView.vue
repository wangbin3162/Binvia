<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { api } from '../api/client'
import type { ProviderConfig, ProviderItem, ProviderUsageSnapshot, RouteConfig } from '../api/types'

const providers = ref<ProviderItem[]>([])
const snapshots = ref<Record<string, ProviderUsageSnapshot>>({})
const config = ref<RouteConfig | null>(null)
const drafts = ref<Record<string, ProviderConfig>>({})
const draftModels = ref<Record<string, string[]>>({})
const newTokens = ref<Record<string, { label: string; value: string }>>({})
const expanded = ref<Record<string, boolean>>({})
const saving = ref<Record<string, boolean>>({})
const messages = ref<Record<string, string>>({})
const testing = ref<Record<string, boolean>>({})
const testResults = ref<Record<string, { success: boolean; message: string }>>({})

function emptyProvider(): ProviderConfig {
  return {
    enabled: true,
    credential: {
      apiKey: null,
      accessToken: null,
      refreshToken: null,
      email: null,
      region: null,
    },
    apiKeys: [],
    region: null,
    disabledModels: [],
  }
}

function clone<T>(value: T): T {
  return JSON.parse(JSON.stringify(value)) as T
}

function syncDrafts() {
  if (!config.value) return
  for (const provider of providers.value) {
    drafts.value[provider.id] = clone(config.value.providers[provider.id] ?? emptyProvider())
    draftModels.value[provider.id] = [...provider.models]
    newTokens.value[provider.id] ??= { label: '', value: '' }
  }
}

async function fetchData() {
  try {
    const [providerResponse, snapshotResponse, configResponse] = await Promise.all([
      api.providers(),
      api.snapshots(),
      api.getConfig(),
    ])
    providers.value = providerResponse.providers
    snapshots.value = snapshotResponse.snapshots
    config.value = configResponse
    syncDrafts()
  } catch (error) {
    messages.value._global = error instanceof Error ? error.message : '加载配置失败'
  }
}

function draftFor(id: string): ProviderConfig {
  if (!drafts.value[id]) drafts.value[id] = emptyProvider()
  return drafts.value[id]
}

function tokenFor(id: string) {
  return newTokens.value[id] ?? (newTokens.value[id] = { label: '', value: '' })
}

function modelsFor(id: string): string[] {
  return draftModels.value[id] ?? []
}

function isModelEnabled(id: string, model: string): boolean {
  return !draftFor(id).disabledModels.includes(model)
}

function setModelEnabled(id: string, model: string, enabled: boolean) {
  const draft = draftFor(id)
  const disabled = new Set(draft.disabledModels)
  if (enabled) disabled.delete(model)
  else disabled.add(model)
  draft.disabledModels = [...disabled]
}

function setAllModels(id: string, enabled: boolean) {
  const draft = draftFor(id)
  draft.disabledModels = enabled ? [] : [...modelsFor(id)]
}

function allModelsEnabled(id: string): boolean {
  const models = modelsFor(id)
  return models.length > 0 && models.every(model => isModelEnabled(id, model))
}

function addToken(id: string) {
  const input = tokenFor(id)
  const value = input.value.trim()
  if (!value) return
  const draft = draftFor(id)
  draft.apiKeys.push({
    label: input.label.trim() || value.slice(0, 6),
    value,
  })
  if (!draft.credential.apiKey) draft.credential.apiKey = value
  newTokens.value[id] = { label: '', value: '' }
}

function removeToken(id: string, index: number) {
  draftFor(id).apiKeys.splice(index, 1)
}

function updateCustomModels(id: string, models: string[]) {
  if (!config.value) return
  const definition = config.value.customProviderDefs.find(item => item.id === id)
  if (definition) definition.models = models
}

function onAllModelsChange(id: string, event: Event) {
  setAllModels(id, (event.target as HTMLInputElement).checked)
}

function onModelChange(id: string, model: string, event: Event) {
  setModelEnabled(id, model, (event.target as HTMLInputElement).checked)
}

function addCustomModel(id: string) {
  const input = tokenFor(`${id}:model`)
  const model = input.value.trim()
  if (!model) return
  const models = [...modelsFor(id)]
  if (!models.includes(model)) {
    models.push(model)
    draftModels.value[id] = models
    updateCustomModels(id, models)
  }
  newTokens.value[`${id}:model`] = { label: '', value: '' }
}

function removeCustomModel(id: string, model: string) {
  const models = modelsFor(id).filter(item => item !== model)
  draftModels.value[id] = models
  updateCustomModels(id, models)
  setModelEnabled(id, model, true)
}

async function saveProvider(provider: ProviderItem) {
  if (!config.value) return
  saving.value[provider.id] = true
  messages.value[provider.id] = ''
  try {
    const next = clone(config.value)
    next.providers[provider.id] = clone(draftFor(provider.id))
    if (provider.isUserDefined) {
      const definition = next.customProviderDefs.find(item => item.id === provider.id)
      if (definition) definition.models = [...modelsFor(provider.id)]
    }
    await api.saveConfig(next)
    config.value = next
    messages.value[provider.id] = '已保存并立即生效'
    await fetchData()
  } catch (error) {
    messages.value[provider.id] = error instanceof Error ? error.message : '保存失败'
  } finally {
    saving.value[provider.id] = false
  }
}

async function testProvider(id: string) {
  testing.value[id] = true
  try {
    testResults.value[id] = await api.testProvider(id)
  } catch (error) {
    testResults.value[id] = {
      success: false,
      message: error instanceof Error ? error.message : '测试失败',
    }
  } finally {
    testing.value[id] = false
  }
}

function mask(value: string): string {
  if (value.length <= 10) return value
  return `${value.slice(0, 6)}••••${value.slice(-4)}`
}

onMounted(fetchData)
</script>

<template>
  <div>
    <div class="flex items-center justify-between mb-4">
      <div>
        <h3 class="text-sm font-medium">Provider 配置</h3>
        <p class="text-xs text-[var(--color-text-secondary)] mt-1">展开供应商，按 macOS 设置窗口方式管理凭据和模型。</p>
      </div>
      <button
        class="text-xs px-3 py-1.5 rounded-lg border border-[var(--color-border)] hover:bg-[var(--color-bg)]"
        @click="fetchData"
      >刷新</button>
    </div>

    <div v-if="messages._global" class="mb-3 rounded-lg border border-[var(--color-red)]/30 bg-red-50 px-3 py-2 text-xs text-[var(--color-red)]">
      {{ messages._global }}
    </div>

    <div class="grid gap-3">
      <section
        v-for="provider in providers"
        :key="provider.id"
        class="bg-white rounded-xl shadow-sm border border-[var(--color-border)] overflow-hidden"
      >
        <button
          class="w-full flex items-center gap-3 px-4 py-3 text-left hover:bg-[var(--color-bg)] transition-colors"
          @click="expanded[provider.id] = !expanded[provider.id]"
        >
          <span class="w-2 h-2 rounded-full" :class="provider.enabled && provider.configured ? 'bg-[var(--color-green)]' : provider.enabled ? 'bg-[var(--color-amber)]' : 'bg-[var(--color-gray)]'"></span>
          <span class="font-medium text-sm flex-1">{{ provider.displayName }}</span>
          <span class="text-xs text-[var(--color-text-secondary)]">{{ provider.authType }} · {{ provider.modelCount }} 模型</span>
          <span class="text-xs text-[var(--color-text-secondary)]">{{ expanded[provider.id] ? '收起' : '配置' }}</span>
          <span class="text-[var(--color-text-secondary)]">{{ expanded[provider.id] ? '⌃' : '⌄' }}</span>
        </button>

        <div v-if="expanded[provider.id]" class="border-t border-[var(--color-border)] bg-[var(--color-bg)]/40 p-4 space-y-4">
          <div class="grid md:grid-cols-[1fr_auto] gap-4">
            <div>
              <div class="text-xs text-[var(--color-text-secondary)] mb-1">Base URL</div>
              <div class="font-mono text-xs truncate" :title="provider.baseURL ?? ''">{{ provider.baseURL || '由内置 Provider 管理' }}</div>
            </div>
            <label class="inline-flex items-center gap-2 text-sm cursor-pointer">
              <input v-model="draftFor(provider.id).enabled" type="checkbox" class="rounded border-[var(--color-border)]" />
              启用 Provider
            </label>
          </div>

          <div class="grid md:grid-cols-2 gap-3">
            <label class="block">
              <span class="text-xs text-[var(--color-text-secondary)]">{{ provider.authType === 'deviceFlow' ? '模型调用 Token' : 'API Key' }}</span>
              <input v-model="draftFor(provider.id).credential.apiKey" type="password" :placeholder="provider.authType === 'deviceFlow' ? '粘贴模型调用 Token' : '留空保持当前值'" class="config-input" />
            </label>
            <label class="block">
              <span class="text-xs text-[var(--color-text-secondary)]">Access Token</span>
              <input v-model="draftFor(provider.id).credential.accessToken" type="password" placeholder="OAuth / Access Token，可选" class="config-input" />
            </label>
            <label class="block">
              <span class="text-xs text-[var(--color-text-secondary)]">Refresh Token</span>
              <input v-model="draftFor(provider.id).credential.refreshToken" type="password" placeholder="可选" class="config-input" />
            </label>
            <label class="block">
              <span class="text-xs text-[var(--color-text-secondary)]">区域</span>
              <input v-model="draftFor(provider.id).region" placeholder="可选，例如 global" class="config-input" />
            </label>
          </div>

          <div>
            <div class="flex items-center justify-between mb-2">
              <div>
                <div class="text-xs font-medium">令牌列表</div>
                <div class="text-[11px] text-[var(--color-text-secondary)]">与 macOS GUI 一致，支持多个 Token 轮换。</div>
              </div>
              <span class="text-[11px] text-[var(--color-text-secondary)]">{{ draftFor(provider.id).apiKeys.length }} 个</span>
            </div>
            <div v-if="draftFor(provider.id).apiKeys.length" class="space-y-1 mb-2">
              <div v-for="(token, index) in draftFor(provider.id).apiKeys" :key="`${token.label}-${index}`" class="flex items-center gap-2 rounded-lg bg-white border border-[var(--color-border)] px-2.5 py-2">
                <span class="text-xs font-medium min-w-20">{{ token.label }}</span>
                <span class="font-mono text-[11px] text-[var(--color-text-secondary)] flex-1 truncate">{{ mask(token.value) }}</span>
                <button class="text-[11px] text-[var(--color-red)] hover:underline" @click="removeToken(provider.id, index)">移除</button>
              </div>
            </div>
            <div class="grid md:grid-cols-[140px_1fr_auto] gap-2">
              <input v-model="tokenFor(provider.id).label" placeholder="标签" class="config-input" />
              <input v-model="tokenFor(provider.id).value" type="password" placeholder="粘贴 API Key / Token" class="config-input" @keyup.enter="addToken(provider.id)" />
              <button class="config-button" @click="addToken(provider.id)">添加</button>
            </div>
          </div>

          <div>
            <div class="flex items-center justify-between mb-2">
              <div>
                <div class="text-xs font-medium">模型</div>
                <div class="text-[11px] text-[var(--color-text-secondary)]">取消勾选后，模型会从模型列表和路由中隐藏。</div>
              </div>
              <label class="inline-flex items-center gap-2 text-xs cursor-pointer">
                <input :checked="allModelsEnabled(provider.id)" type="checkbox" class="rounded border-[var(--color-border)]" @change="onAllModelsChange(provider.id, $event)" />
                全部启用
              </label>
            </div>
            <div v-if="modelsFor(provider.id).length" class="grid sm:grid-cols-2 gap-1.5">
              <label v-for="model in modelsFor(provider.id)" :key="model" class="flex items-center gap-2 rounded-lg px-2.5 py-2 bg-white border border-[var(--color-border)] text-xs cursor-pointer hover:border-[var(--color-blue)]">
                <input :checked="isModelEnabled(provider.id, model)" type="checkbox" class="rounded border-[var(--color-border)]" @change="onModelChange(provider.id, model, $event)" />
                <span :class="isModelEnabled(provider.id, model) ? '' : 'line-through text-[var(--color-text-secondary)]'">{{ model }}</span>
              </label>
            </div>
            <div v-else class="text-xs text-[var(--color-text-secondary)]">暂无模型。自定义 Provider 可在下方添加。</div>
            <div v-if="provider.isUserDefined" class="grid md:grid-cols-[1fr_auto] gap-2 mt-2">
              <input v-model="tokenFor(`${provider.id}:model`).value" placeholder="添加自定义模型名，例如 glm-4.5" class="config-input" @keyup.enter="addCustomModel(provider.id)" />
              <button class="config-button" @click="addCustomModel(provider.id)">添加模型</button>
            </div>
            <div v-if="provider.isUserDefined && modelsFor(provider.id).length" class="flex flex-wrap gap-1.5 mt-2">
              <button v-for="model in modelsFor(provider.id)" :key="`remove-${model}`" class="text-[11px] px-2 py-1 rounded-md bg-white border border-[var(--color-border)] hover:border-[var(--color-red)] hover:text-[var(--color-red)]" @click="removeCustomModel(provider.id, model)">
                {{ model }} ×
              </button>
            </div>
          </div>

          <div class="flex items-center justify-between gap-3 pt-1">
            <span v-if="messages[provider.id]" class="text-xs text-[var(--color-green)]">{{ messages[provider.id] }}</span>
            <span v-else></span>
            <div class="flex gap-2">
              <button class="config-button" :disabled="testing[provider.id]" @click="testProvider(provider.id)">{{ testing[provider.id] ? '测试中…' : '测试连接' }}</button>
              <button class="config-button config-button-primary" :disabled="saving[provider.id]" @click="saveProvider(provider)">{{ saving[provider.id] ? '保存中…' : '保存并应用' }}</button>
            </div>
          </div>
          <div v-if="testResults[provider.id]" class="text-xs" :class="testResults[provider.id].success ? 'text-[var(--color-green)]' : 'text-[var(--color-red)]'">
            {{ testResults[provider.id].message }}
          </div>
        </div>
      </section>
    </div>
  </div>
</template>

<style scoped>
@reference "../styles/main.css";

.config-input {
  @apply w-full px-3 py-2 border border-[var(--color-border)] rounded-lg text-xs bg-white outline-none focus:border-[var(--color-blue)];
}

.config-button {
  @apply text-xs px-3 py-2 rounded-lg border border-[var(--color-border)] bg-white hover:bg-[var(--color-bg)] disabled:opacity-50;
}

.config-button-primary {
  @apply border-[var(--color-blue)] bg-[var(--color-blue)] text-white hover:opacity-90;
}
</style>
