<script setup lang="ts">
import { ref, onMounted, onUnmounted } from 'vue'
import { api } from '../api/client'
import type { RequestLogEntry } from '../api/types'

const entries = ref<RequestLogEntry[]>([])
let pollTimer: ReturnType<typeof setInterval> | null = null

async function fetchEntries() {
  try {
    entries.value = (await api.entries(100)).entries
  } catch {
    // silent
  }
}

function formatTime(ts: string): string {
  const d = new Date(ts)
  return d.toLocaleTimeString('zh-CN', { hour: '2-digit', minute: '2-digit', second: '2-digit' })
}

function statusClass(code: number): string {
  if (code >= 200 && code < 300) return 'text-[var(--color-green)]'
  if (code >= 400) return 'text-[var(--color-red)]'
  return 'text-[var(--color-amber)]'
}

onMounted(() => {
  fetchEntries()
  pollTimer = setInterval(fetchEntries, 2000)
})

onUnmounted(() => {
  if (pollTimer) clearInterval(pollTimer)
})
</script>

<template>
  <div>
    <div class="flex items-center justify-between mb-4">
      <h3 class="text-sm font-medium">请求日志（2s 自动刷新）</h3>
      <span class="text-xs text-[var(--color-text-secondary)]">{{ entries.length }} 条</span>
    </div>
    <div class="bg-white rounded-xl shadow-sm border border-[var(--color-border)] overflow-x-auto">
      <table class="w-full text-xs">
        <thead>
          <tr class="border-b border-[var(--color-border)] bg-[var(--color-bg)]">
            <th class="text-left px-3 py-2 font-medium">时间</th>
            <th class="text-left px-3 py-2 font-medium">方法</th>
            <th class="text-left px-3 py-2 font-medium">路径</th>
            <th class="text-left px-3 py-2 font-medium">Provider</th>
            <th class="text-left px-3 py-2 font-medium">模型</th>
            <th class="text-right px-3 py-2 font-medium">状态</th>
            <th class="text-right px-3 py-2 font-medium">耗时</th>
            <th class="text-right px-3 py-2 font-medium">Token</th>
            <th class="text-left px-3 py-2 font-medium">错误</th>
          </tr>
        </thead>
        <tbody>
          <tr
            v-for="e in entries"
            :key="e.id"
            class="border-b border-[var(--color-border)] last:border-0 hover:bg-[var(--color-bg)]"
          >
            <td class="px-3 py-2 whitespace-nowrap">{{ formatTime(e.timestamp) }}</td>
            <td class="px-3 py-2 font-mono">{{ e.method }}</td>
            <td class="px-3 py-2 font-mono max-w-40 truncate">{{ e.path }}</td>
            <td class="px-3 py-2">{{ e.providerID ?? '-' }}</td>
            <td class="px-3 py-2 max-w-40 truncate">{{ e.model ?? '-' }}</td>
            <td class="px-3 py-2 text-right font-mono" :class="statusClass(e.statusCode)">{{ e.statusCode }}</td>
            <td class="px-3 py-2 text-right">{{ e.durationMS.toFixed(0) }}ms</td>
            <td class="px-3 py-2 text-right">
              {{ e.tokens ? e.tokens.totalTokens : '-' }}
            </td>
            <td class="px-3 py-2 max-w-40 truncate text-[var(--color-red)]">{{ e.error ?? '' }}</td>
          </tr>
          <tr v-if="entries.length === 0">
            <td colspan="9" class="px-3 py-6 text-center text-[var(--color-text-secondary)]">暂无请求记录</td>
          </tr>
        </tbody>
      </table>
    </div>
  </div>
</template>