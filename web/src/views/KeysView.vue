<script setup lang="ts">
import { computed, ref, onMounted } from 'vue'
import { api } from '../api/client'
import type { GatewayKeyConfig, ProviderItem, RouteConfig } from '../api/types'

const config = ref<RouteConfig | null>(null)
const providers = ref<ProviderItem[]>([])
const expanded = ref<Record<string, boolean>>({})
const limited = ref<Record<string, boolean>>({})
const selected = ref<Record<string, Set<string>>>({})
const keys = ref<GatewayKeyConfig[]>([])
const loading = ref(false)
const message = ref('')
const newKey = ref('')
const newKeyEnabledModels = ref('')
const showCreate = ref(false)

const modelOptions = computed(() => providers.value
  .filter(provider => provider.enabled && provider.configured)
  .flatMap(provider => provider.models.map(model => ({
    id: `${provider.alias || provider.id}/${model}`,
    providerID: provider.id,
    providerName: provider.displayName,
  }))))

const groupedOptions = computed(() => {
  const groups = new Map<string, { providerID: string; providerName: string; options: typeof modelOptions.value }>()
  for (const option of modelOptions.value) {
    const current = groups.get(option.providerID) ?? { providerID: option.providerID, providerName: option.providerName, options: [] }
    current.options.push(option)
    groups.set(option.providerID, current)
  }
  return [...groups.values()]
})

function fetchKeys() {
  return Promise.all([api.getConfig(), api.providers()]).then(([nextConfig, nextProviders]) => {
    config.value = nextConfig
    providers.value = nextProviders.providers
    keys.value = nextConfig.apiKeys
    for (const key of keys.value) {
      limited.value[key.key] = key.enabledModels !== null
      selected.value[key.key] = new Set(key.enabledModels ?? [])
    }
  })
}

function enterLimited(key: GatewayKeyConfig) {
  limited.value[key.key] = true
  selected.value[key.key] ??= new Set(key.enabledModels ?? [])
}

function allEnabled(key: GatewayKeyConfig): boolean {
  return !limited.value[key.key]
}

function toggleModel(key: GatewayKeyConfig, modelID: string, enabled: boolean) {
  enterLimited(key)
  const next = new Set(selected.value[key.key] ?? [])
  if (enabled) next.add(modelID)
  else next.delete(modelID)
  selected.value[key.key] = next
}

function onAllEnabledChange(key: GatewayKeyConfig, event: Event) {
  if ((event.target as HTMLInputElement).checked) void clearWhitelist(key)
  else enterLimited(key)
}

function onKeyModelChange(key: GatewayKeyConfig, modelID: string, event: Event) {
  toggleModel(key, modelID, (event.target as HTMLInputElement).checked)
}

async function applyWhitelist(key: GatewayKeyConfig) {
  const models = [...(selected.value[key.key] ?? [])].sort()
  await api.createKey(key.key, models)
  key.enabledModels = models
  limited.value[key.key] = true
  message.value = models.length ? `已保存 ${models.length} 个模型` : '已保存，当前 Key 不允许任何模型'
  clearMessage()
}

async function clearWhitelist(key: GatewayKeyConfig) {
  await api.createKey(key.key)
  key.enabledModels = null
  limited.value[key.key] = false
  selected.value[key.key] = new Set()
  message.value = '已保存，全部模型可用'
  clearMessage()
}

async function createKey() {
  const enabledModels = newKeyEnabledModels.value
    ? newKeyEnabledModels.value.split(',').map(value => value.trim()).filter(Boolean)
    : undefined
  await api.createKey(newKey.value || undefined, enabledModels)
  newKey.value = ''
  newKeyEnabledModels.value = ''
  showCreate.value = false
  await fetchKeys()
}

async function deleteKey(key: string) {
  await api.deleteKey(key)
  await fetchKeys()
}

function maskKey(key: string): string {
  if (key.length <= 10) return key
  return `${key.slice(0, 6)}••••${key.slice(-4)}`
}

async function copyKey(key: string) {
  await navigator.clipboard.writeText(key)
  message.value = '完整 Key 已复制'
  clearMessage()
}

function clearMessage() {
  window.setTimeout(() => { message.value = '' }, 2500)
}

onMounted(async () => {
  loading.value = true
  try {
    await fetchKeys()
  } finally {
    loading.value = false
  }
})
</script>

<template>
  <div>
    <div class="flex items-center justify-between mb-4">
      <div>
        <h3 class="text-sm font-medium">网关 Keys</h3>
        <p class="text-xs text-[var(--color-text-secondary)] mt-1">为每个 Key 单独限制可调用模型，行为贴近 macOS 网关密钥设置。</p>
      </div>
      <button class="text-xs px-3 py-1.5 rounded-lg bg-[var(--color-blue)] text-white hover:opacity-90" @click="showCreate = !showCreate">
        {{ showCreate ? '取消' : '新建 Key' }}
      </button>
    </div>

    <div v-if="message" class="mb-3 text-xs text-[var(--color-green)]">{{ message }}</div>

    <div v-if="showCreate" class="bg-white rounded-xl shadow-sm border border-[var(--color-border)] p-4 mb-4 space-y-3">
      <label class="block">
        <span class="text-xs text-[var(--color-text-secondary)]">Key（留空自动生成）</span>
        <input v-model="newKey" placeholder="sk-bv-..." class="config-input mt-1" />
      </label>
      <label class="block">
        <span class="text-xs text-[var(--color-text-secondary)]">模型白名单（逗号分隔，留空全部放行）</span>
        <input v-model="newKeyEnabledModels" placeholder="ds/deepseek-v4-pro, oa/gpt-4o" class="config-input mt-1" />
      </label>
      <button class="config-button config-button-primary" @click="createKey">创建</button>
    </div>

    <div v-if="loading" class="rounded-xl border border-[var(--color-border)] bg-white p-6 text-center text-xs text-[var(--color-text-secondary)]">加载中…</div>
    <div v-else class="bg-white rounded-xl shadow-sm border border-[var(--color-border)] divide-y divide-[var(--color-border)]">
      <div v-for="key in keys" :key="key.key" class="p-4">
        <div class="flex items-center gap-3">
          <span class="text-[var(--color-blue)]">⌘</span>
          <span class="font-mono text-sm flex-1">{{ maskKey(key.key) }}</span>
          <span class="text-xs text-[var(--color-text-secondary)]">
            {{ allEnabled(key) ? '全部模型' : `${selected[key.key]?.size ?? 0} 个模型` }}
          </span>
          <button class="text-xs text-[var(--color-text-secondary)] hover:text-[var(--color-blue)]" @click="copyKey(key.key)">复制</button>
          <button class="text-xs text-[var(--color-red)] hover:underline" @click="deleteKey(key.key)">删除</button>
        </div>

        <button class="mt-3 text-xs text-[var(--color-text-secondary)] hover:text-[var(--color-blue)]" @click="expanded[key.key] = !expanded[key.key]">
          {{ expanded[key.key] ? '收起模型白名单' : '编辑模型白名单' }} · {{ expanded[key.key] ? '⌃' : '⌄' }}
        </button>

        <div v-if="expanded[key.key]" class="mt-3 rounded-lg bg-[var(--color-bg)] p-3 space-y-3">
          <label class="flex items-center gap-2 text-xs cursor-pointer">
            <input :checked="allEnabled(key)" type="checkbox" class="rounded border-[var(--color-border)]" @change="onAllEnabledChange(key, $event)" />
            全部启用（不限制模型）
          </label>
          <div v-if="limited[key.key] && groupedOptions.length" class="space-y-2">
            <div v-for="group in groupedOptions" :key="group.providerID" class="rounded-lg bg-white border border-[var(--color-border)] p-2">
              <div class="text-xs font-medium mb-1">{{ group.providerName }}</div>
              <label v-for="option in group.options" :key="option.id" class="flex items-center gap-2 py-1 text-xs cursor-pointer">
                <input :checked="selected[key.key]?.has(option.id)" type="checkbox" class="rounded border-[var(--color-border)]" @change="onKeyModelChange(key, option.id, $event)" />
                <span>{{ option.id }}</span>
              </label>
            </div>
          </div>
          <div v-else-if="limited[key.key]" class="text-xs text-[var(--color-text-secondary)]">当前没有已配置凭据的可用模型。</div>
          <div class="flex justify-end gap-2">
            <button class="config-button" @click="clearWhitelist(key)">清除限制</button>
            <button class="config-button config-button-primary" :disabled="!limited[key.key]" @click="applyWhitelist(key)">应用白名单</button>
          </div>
        </div>
      </div>
      <div v-if="keys.length === 0" class="px-4 py-6 text-center text-xs text-[var(--color-text-secondary)]">暂无网关 Key</div>
    </div>
  </div>
</template>

<style scoped>
@reference "../styles/main.css";

.config-input {
  @apply w-full px-3 py-2 border border-[var(--color-border)] rounded-lg text-sm bg-white outline-none focus:border-[var(--color-blue)];
}

.config-button {
  @apply text-xs px-3 py-2 rounded-lg border border-[var(--color-border)] bg-white hover:bg-[var(--color-bg)] disabled:opacity-50;
}

.config-button-primary {
  @apply border-[var(--color-blue)] bg-[var(--color-blue)] text-white hover:opacity-90;
}
</style>
