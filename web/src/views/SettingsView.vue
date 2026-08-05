<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { api } from '../api/client'
import type { RouteConfig } from '../api/types'

const config = ref<RouteConfig | null>(null)
const saving = ref(false)
const saveMessage = ref('')

async function fetchConfig() {
  config.value = await api.getConfig()
}

async function saveConfig() {
  if (!config.value) return
  saving.value = true
  saveMessage.value = ''
  try {
    await api.saveConfig(config.value)
    saveMessage.value = '保存成功'
  } catch {
    saveMessage.value = '保存失败'
  }
  saving.value = false
  setTimeout(() => { saveMessage.value = '' }, 3000)
}

onMounted(fetchConfig)
</script>

<template>
  <div>
    <div class="flex items-center justify-between mb-4">
      <h3 class="text-sm font-medium">服务器设置</h3>
      <button
        class="text-xs px-3 py-1.5 rounded-lg bg-[var(--color-blue)] text-white hover:opacity-90 disabled:opacity-50"
        :disabled="saving || !config"
        @click="saveConfig"
      >{{ saving ? '保存中…' : '保存' }}</button>
    </div>

    <div v-if="config" class="bg-white rounded-xl shadow-sm border border-[var(--color-border)] p-4 space-y-4">
      <div class="grid grid-cols-2 gap-4">
        <div>
          <label class="text-xs text-[var(--color-text-secondary)] block mb-1">监听地址</label>
          <input
            v-model="config.host"
            class="w-full px-3 py-2 border border-[var(--color-border)] rounded-lg text-sm outline-none focus:border-[var(--color-blue)]"
          />
        </div>
        <div>
          <label class="text-xs text-[var(--color-text-secondary)] block mb-1">端口</label>
          <input
            v-model.number="config.port"
            type="number"
            class="w-full px-3 py-2 border border-[var(--color-border)] rounded-lg text-sm outline-none focus:border-[var(--color-blue)]"
          />
        </div>
      </div>
      <div class="flex items-center gap-2">
        <input
          v-model="config.webPanelEnabled"
          type="checkbox"
          id="webPanelEnabled"
          class="rounded border-[var(--color-border)]"
        />
        <label for="webPanelEnabled" class="text-sm">启用 Web 管理面板</label>
      </div>
      <div>
        <label class="text-xs text-[var(--color-text-secondary)] block mb-1">管理员密码（留空为无密码）</label>
        <input
          v-model="config.adminPassword"
          type="password"
          placeholder="留空不设密码"
          class="w-full px-3 py-2 border border-[var(--color-border)] rounded-lg text-sm outline-none focus:border-[var(--color-blue)]"
        />
      </div>
      <div v-if="saveMessage" class="text-xs" :class="saveMessage === '保存成功' ? 'text-[var(--color-green)]' : 'text-[var(--color-red)]'">
        {{ saveMessage }}
      </div>
    </div>
    <div v-else class="bg-white rounded-xl shadow-sm border border-[var(--color-border)] p-6 text-center text-sm text-[var(--color-text-secondary)]">
      加载中…
    </div>
  </div>
</template>