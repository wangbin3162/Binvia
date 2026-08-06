<script setup lang="ts">
import { ref, computed, onMounted } from 'vue'
import { api } from '../api/client'
import type { ProviderItem } from '../api/types'

const providers = ref<ProviderItem[]>([])
const selectedProvider = ref('')
const selectedModel = ref('')
const message = ref('')
const output = ref('')
const sending = ref(false)
const errorMessage = ref('')
const tokens = ref<{ promptTokens: number; completionTokens: number; totalTokens: number } | null>(null)
let abortController: AbortController | null = null

const availableModels = computed(() => {
  const provider = providers.value.find(p => p.id === selectedProvider.value)
  if (!provider) return [] as string[]
  return provider.models.map(m => `${provider.alias || provider.id}/${m}`)
})

const fullModel = computed(() => {
  if (selectedModel.value) return selectedModel.value
  return availableModels.value[0] ?? ''
})

async function fetchProviders() {
  const response = await api.providers()
  providers.value = response.providers.filter(p => p.enabled && p.configured)
  if (!selectedProvider.value && providers.value.length) {
    selectedProvider.value = providers.value[0].id
  }
}

async function send() {
  if (!fullModel.value || !message.value.trim() || sending.value) return
  sending.value = true
  output.value = ''
  errorMessage.value = ''
  tokens.value = null
  abortController = new AbortController()
  try {
    const result = await api.playgroundStream(
      fullModel.value,
      message.value,
      (chunk) => { output.value += chunk },
      abortController.signal,
    )
    tokens.value = result.tokens
  } catch (error) {
    errorMessage.value = error instanceof Error ? error.message : '发送失败'
  } finally {
    sending.value = false
    abortController = null
  }
}

function stop() {
  abortController?.abort()
  sending.value = false
}

function clearOutput() {
  output.value = ''
  errorMessage.value = ''
  tokens.value = null
}

onMounted(fetchProviders)
</script>

<template>
  <div class="space-y-4">
    <div class="flex items-center justify-between">
      <div>
        <h3 class="text-sm font-medium">聊天试玩</h3>
        <p class="text-xs text-[var(--color-text-secondary)] mt-1">以管理员身份直接调用网关，发送消息验证模型可用性（流式）。</p>
      </div>
    </div>

    <div class="bg-white rounded-xl shadow-sm border border-[var(--color-border)] p-4 space-y-3">
      <div class="grid md:grid-cols-2 gap-3">
        <label class="block">
          <span class="text-xs text-[var(--color-text-secondary)]">Provider</span>
          <select v-model="selectedProvider" class="config-input mt-1">
            <option v-for="p in providers" :key="p.id" :value="p.id">{{ p.displayName }}</option>
          </select>
        </label>
        <label class="block">
          <span class="text-xs text-[var(--color-text-secondary)]">模型</span>
          <select v-model="selectedModel" class="config-input mt-1">
            <option v-for="m in availableModels" :key="m" :value="m">{{ m }}</option>
          </select>
        </label>
      </div>

      <label class="block">
        <span class="text-xs text-[var(--color-text-secondary)]">消息</span>
        <textarea
          v-model="message"
          rows="3"
          placeholder="输入测试消息，例如：你好，请用一句话介绍自己。"
          class="config-input mt-1 resize-y"
          @keydown.ctrl.enter="send"
        />
      </label>

      <div class="flex items-center gap-2">
        <button
          class="config-button config-button-primary"
          :disabled="sending || !fullModel || !message.trim()"
          @click="send"
        >{{ sending ? '发送中…' : '发送（Ctrl+Enter）' }}</button>
        <button v-if="sending" class="config-button" @click="stop">停止</button>
        <button class="config-button" @click="clearOutput">清空</button>
        <span v-if="tokens" class="text-xs text-[var(--color-text-secondary)] ml-auto">
          Token: {{ tokens.totalTokens }}（prompt {{ tokens.promptTokens }} + completion {{ tokens.completionTokens }}）
        </span>
      </div>
    </div>

    <div class="bg-white rounded-xl shadow-sm border border-[var(--color-border)] p-4 min-h-48">
      <div class="text-xs font-medium mb-2">回复</div>
      <div v-if="errorMessage" class="text-xs text-[var(--color-red)]">{{ errorMessage }}</div>
      <pre v-else class="text-sm whitespace-pre-wrap break-words font-sans">{{ output || '（暂无输出）' }}</pre>
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
