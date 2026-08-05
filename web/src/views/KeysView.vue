<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { api } from '../api/client'
import type { GatewayKeyConfig } from '../api/types'

const keys = ref<GatewayKeyConfig[]>([])
const newKey = ref('')
const newKeyEnabledModels = ref('')
const showCreate = ref(false)

async function fetchKeys() {
  const cfg = await api.getConfig()
  keys.value = cfg.apiKeys
}

async function createKey() {
  const enabledModels = newKeyEnabledModels.value
    ? newKeyEnabledModels.value.split(',').map(s => s.trim()).filter(Boolean)
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
  return key.slice(0, 6) + '••••' + key.slice(-4)
}

onMounted(fetchKeys)
</script>

<template>
  <div>
    <div class="flex items-center justify-between mb-4">
      <h3 class="text-sm font-medium">网关 Keys</h3>
      <button
        class="text-xs px-3 py-1.5 rounded-lg bg-[var(--color-blue)] text-white hover:opacity-90"
        @click="showCreate = !showCreate"
      >{{ showCreate ? '取消' : '新建 Key' }}</button>
    </div>

    <!-- 新建表单 -->
    <div v-if="showCreate" class="bg-white rounded-xl shadow-sm border border-[var(--color-border)] p-4 mb-4">
      <div class="grid gap-3">
        <div>
          <label class="text-xs text-[var(--color-text-secondary)] block mb-1">Key（留空自动生成）</label>
          <input
            v-model="newKey"
            placeholder="sk-bv-..."
            class="w-full px-3 py-2 border border-[var(--color-border)] rounded-lg text-sm outline-none focus:border-[var(--color-blue)]"
          />
        </div>
        <div>
          <label class="text-xs text-[var(--color-text-secondary)] block mb-1">模型白名单（逗号分隔，留空全部放行）</label>
          <input
            v-model="newKeyEnabledModels"
            placeholder="ds/deepseek-v4-pro, cbcn/glm-5.2"
            class="w-full px-3 py-2 border border-[var(--color-border)] rounded-lg text-sm outline-none focus:border-[var(--color-blue)]"
          />
        </div>
        <button
          class="self-start text-xs px-4 py-1.5 rounded-lg bg-[var(--color-blue)] text-white hover:opacity-90"
          @click="createKey"
        >创建</button>
      </div>
    </div>

    <!-- Key 列表 -->
    <div class="bg-white rounded-xl shadow-sm border border-[var(--color-border)]">
      <div
        v-for="k in keys"
        :key="k.key"
        class="flex items-center gap-3 px-4 py-3 border-b border-[var(--color-border)] last:border-0"
      >
        <span class="font-mono text-sm flex-1">{{ maskKey(k.key) }}</span>
        <span class="text-xs text-[var(--color-text-secondary)]">
          {{ k.enabledModels ? `${k.enabledModels.length} 个模型` : '全部模型' }}
        </span>
        <button
          class="text-xs px-2 py-1 rounded border border-[var(--color-red)] text-[var(--color-red)] hover:bg-red-50"
          @click="deleteKey(k.key)"
        >删除</button>
      </div>
      <div v-if="keys.length === 0" class="px-4 py-6 text-center text-xs text-[var(--color-text-secondary)]">
        暂无网关 Key
      </div>
    </div>
  </div>
</template>