<script setup lang="ts">
import { ref, onMounted, onUnmounted } from 'vue'
import { api } from '../api/client'
import type { ProviderItem, ProviderUsageSnapshot, RouteConfig } from '../api/types'

const providers = ref<ProviderItem[]>([])
const snapshots = ref<Record<string, ProviderUsageSnapshot>>({})
const config = ref<RouteConfig | null>(null)
const testing = ref<Record<string, boolean>>({})
const testResults = ref<Record<string, { success: boolean; message: string }>>({})

async function fetchData() {
  providers.value = (await api.providers()).providers
  snapshots.value = (await api.snapshots()).snapshots
  config.value = await api.getConfig()
}

async function testProvider(id: string) {
  testing.value[id] = true
  testResults.value[id] = await api.testProvider(id)
  testing.value[id] = false
}

function providerConfig(id: string) {
  return config.value?.providers[id]
}

function hasCredential(id: string, p: ProviderItem): boolean {
  return p.configured
}

function authTypeLabel(t: string): string {
  return { apiKey: 'API Key', oauth: 'OAuth', deviceFlow: '设备码', localProbe: '本地探测' }[t] ?? t
}

onMounted(fetchData)
</script>

<template>
  <div>
    <div class="flex items-center justify-between mb-4">
      <h3 class="text-sm font-medium">Provider 列表</h3>
      <button
        class="text-xs px-3 py-1.5 rounded-lg bg-[var(--color-blue)] text-white hover:opacity-90"
        @click="fetchData"
      >刷新</button>
    </div>
    <div class="grid gap-4">
      <div
        v-for="p in providers"
        :key="p.id"
        class="bg-white rounded-xl shadow-sm border border-[var(--color-border)] p-4"
      >
        <div class="flex items-center justify-between mb-2">
          <div class="flex items-center gap-2">
            <span
              class="w-2 h-2 rounded-full"
              :class="p.enabled && p.configured ? 'bg-[var(--color-green)]' : p.enabled ? 'bg-[var(--color-amber)]' : 'bg-[var(--color-gray)]'"
            ></span>
            <span class="font-medium text-sm">{{ p.displayName }}</span>
            <span class="text-xs text-[var(--color-text-secondary)]">({{ p.id }})</span>
          </div>
          <span class="text-xs text-[var(--color-text-secondary)]">
            {{ authTypeLabel(p.authType) }} · {{ p.modelCount }} 模型
          </span>
        </div>
        <div class="flex items-center gap-3 text-xs text-[var(--color-text-secondary)] mb-3">
          <span :class="p.enabled ? 'text-[var(--color-green)]' : 'text-[var(--color-red)]'">
            {{ p.enabled ? '已启用' : '已禁用' }}
          </span>
          <span>{{ p.configured ? '已配置凭据' : '未配置凭据' }}</span>
          <span v-if="p.region">区域: {{ p.region }}</span>
        </div>
        <!-- 用量快照 -->
        <div v-if="snapshots[p.id] && !snapshots[p.id]?.error" class="mb-3">
          <div class="flex flex-wrap gap-3">
            <div
              v-for="w in snapshots[p.id]?.quotaWindows ?? []"
              :key="w.label"
              class="text-xs bg-[var(--color-bg)] rounded-lg px-2 py-1"
            >
              {{ w.label }}: {{ Math.round(w.remainingPercentage) }}%
            </div>
            <div v-if="snapshots[p.id]?.balance != null" class="text-xs bg-[var(--color-bg)] rounded-lg px-2 py-1">
              余额: {{ snapshots[p.id]?.currency ?? '' }} {{ snapshots[p.id]?.balance }}
            </div>
          </div>
        </div>
        <div v-else-if="snapshots[p.id]?.error" class="text-xs text-[var(--color-red)] mb-2">
          {{ snapshots[p.id]?.error }}
        </div>
        <!-- 操作 -->
        <div class="flex gap-2">
          <button
            class="text-xs px-3 py-1 rounded-lg border border-[var(--color-border)] hover:bg-[var(--color-bg)] disabled:opacity-50"
            :disabled="testing[p.id]"
            @click="testProvider(p.id)"
          >
            {{ testing[p.id] ? '测试中…' : '测试连通性' }}
          </button>
          <span
            v-if="testResults[p.id]"
            class="text-xs self-center"
            :class="testResults[p.id].success ? 'text-[var(--color-green)]' : 'text-[var(--color-red)]'"
          >{{ testResults[p.id].message }}</span>
        </div>
      </div>
    </div>
  </div>
</template>