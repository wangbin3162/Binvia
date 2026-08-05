<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { api } from '../api/client'
import type { CustomProviderDef, RouteConfig } from '../api/types'

const config = ref<RouteConfig | null>(null)
const saving = ref(false)
const saveMessage = ref('')
const newName = ref('')
const newBaseURL = ref('')
const newModels = ref('')
const customError = ref('')

async function fetchConfig() {
  config.value = await api.getConfig()
}

async function saveConfig() {
  if (!config.value) return
  saving.value = true
  saveMessage.value = ''
  try {
    await api.saveConfig(config.value)
    saveMessage.value = '保存成功，配置已立即生效'
  } catch (error) {
    saveMessage.value = error instanceof Error ? error.message : '保存失败'
  } finally {
    saving.value = false
  }
  window.setTimeout(() => { saveMessage.value = '' }, 3000)
}

function slugify(name: string): string {
  const slug = name.trim().toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '')
  return slug || `custom-${Date.now()}`
}

function addCustomProvider() {
  if (!config.value) return
  customError.value = ''
  const name = newName.value.trim()
  const baseURL = newBaseURL.value.trim()
  if (!name || !baseURL) {
    customError.value = '名称和 Base URL 不能为空'
    return
  }
  try {
    const parsed = new URL(baseURL)
    if (!['http:', 'https:'].includes(parsed.protocol)) throw new Error()
  } catch {
    customError.value = 'Base URL 必须是合法的 http/https 地址'
    return
  }
  let id = slugify(name)
  let suffix = 2
  while (config.value.customProviderDefs.some(item => item.id === id)) id = `${slugify(name)}-${suffix++}`
  config.value.customProviderDefs.push({
    id,
    displayName: name,
    baseURL,
    models: newModels.value.split(',').map(value => value.trim()).filter(Boolean),
  })
  newName.value = ''
  newBaseURL.value = ''
  newModels.value = ''
}

function removeCustomProvider(provider: CustomProviderDef) {
  if (!config.value) return
  config.value.customProviderDefs = config.value.customProviderDefs.filter(item => item.id !== provider.id)
  delete config.value.providers[provider.id]
}

onMounted(fetchConfig)
</script>

<template>
  <div class="space-y-5">
    <div class="flex items-center justify-between">
      <div>
        <h3 class="text-sm font-medium">服务器与兼容 Provider</h3>
        <p class="text-xs text-[var(--color-text-secondary)] mt-1">对应 macOS 设置窗口的“服务器”和“自定义供应商”面板。</p>
      </div>
      <button class="config-button config-button-primary" :disabled="saving || !config" @click="saveConfig">{{ saving ? '保存中…' : '保存并应用' }}</button>
    </div>

    <div v-if="config" class="bg-white rounded-xl shadow-sm border border-[var(--color-border)] p-4 space-y-4">
      <div class="text-xs font-medium">服务器</div>
      <div class="grid md:grid-cols-2 gap-4">
        <label>
          <span class="field-label">监听地址</span>
          <input v-model="config.host" class="config-input" />
        </label>
        <label>
          <span class="field-label">监听端口</span>
          <input v-model.number="config.port" type="number" min="1" max="65535" class="config-input" />
        </label>
      </div>
      <div class="text-[11px] text-[var(--color-text-secondary)]">建议保持 127.0.0.1，仅监听本机回环地址。</div>
      <label class="flex items-center gap-2 text-sm cursor-pointer">
        <input v-model="config.webPanelEnabled" type="checkbox" class="rounded border-[var(--color-border)]" />
        启用 Web 管理面板
      </label>
      <label>
        <span class="field-label">管理员密码</span>
        <input v-model="config.adminPassword" type="password" placeholder="留空为无密码；未修改时保留当前密码" class="config-input" />
      </label>
      <div v-if="saveMessage" class="text-xs text-[var(--color-green)]">{{ saveMessage }}</div>
    </div>

    <div v-if="config" class="bg-white rounded-xl shadow-sm border border-[var(--color-border)] p-4 space-y-4">
      <div>
        <div class="text-xs font-medium">自定义 OpenAI 兼容 Provider</div>
        <div class="text-[11px] text-[var(--color-text-secondary)] mt-1">添加后到 Provider 页配置凭据和模型，调用格式为 provider/model。</div>
      </div>
      <div v-if="config.customProviderDefs.length" class="space-y-2">
        <div v-for="provider in config.customProviderDefs" :key="provider.id" class="flex items-center gap-3 rounded-lg border border-[var(--color-border)] px-3 py-2">
          <span class="w-7 h-7 rounded-lg bg-[var(--color-bg)] flex items-center justify-center text-xs font-semibold">{{ provider.displayName.slice(0, 1) }}</span>
          <div class="min-w-0 flex-1">
            <div class="text-xs font-medium">{{ provider.displayName }} <span class="text-[var(--color-text-secondary)]">({{ provider.id }})</span></div>
            <div class="text-[11px] text-[var(--color-text-secondary)] truncate">{{ provider.baseURL }} · {{ provider.models.length }} 个模型</div>
          </div>
          <button class="text-xs text-[var(--color-red)] hover:underline" @click="removeCustomProvider(provider)">删除</button>
        </div>
      </div>
      <div v-else class="text-xs text-[var(--color-text-secondary)]">尚未添加自定义 Provider。</div>
      <div class="grid md:grid-cols-3 gap-2">
        <input v-model="newName" placeholder="供应商名称" class="config-input" />
        <input v-model="newBaseURL" placeholder="https://api.example.com/v1" class="config-input" />
        <input v-model="newModels" placeholder="模型名，逗号分隔（可选）" class="config-input" />
      </div>
      <div class="flex items-center justify-between gap-3">
        <span v-if="customError" class="text-xs text-[var(--color-red)]">{{ customError }}</span>
        <span v-else></span>
        <button class="config-button" @click="addCustomProvider">添加 Provider</button>
      </div>
    </div>

    <div v-else class="bg-white rounded-xl shadow-sm border border-[var(--color-border)] p-6 text-center text-sm text-[var(--color-text-secondary)]">加载中…</div>
  </div>
</template>

<style scoped>
@reference "../styles/main.css";

.field-label {
  @apply text-xs text-[var(--color-text-secondary)] block mb-1;
}

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
