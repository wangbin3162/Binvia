<script setup lang="ts">
import { ref, computed } from 'vue'
import { api } from '../api/client'
import type { OverviewResponse } from '../api/types'

const props = defineProps<{
  overview: OverviewResponse | null
}>()

const providerTests = ref<Record<string, { testing: boolean; success?: boolean; message?: string }>>({})

async function testProvider(id: string) {
  providerTests.value[id] = { testing: true }
  const result = await api.testProvider(id)
  providerTests.value[id] = { testing: false, success: result.success, message: result.message }
}

function statusColor(enabled: boolean, configured: boolean): string {
  if (enabled && configured) return 'var(--color-green)'
  if (enabled && !configured) return 'var(--color-amber)'
  return 'var(--color-gray)'
}

const summaryItems = computed(() => {
  const s = props.overview?.summary
  if (!s) return []
  return [
    { label: '总请求', value: s.totalRequests.toLocaleString() },
    { label: '总错误', value: s.totalErrors.toLocaleString() },
    { label: '活跃 Provider', value: s.activeProviders.toString() },
    { label: 'Prompt Token', value: s.promptTokens.toLocaleString() },
    { label: 'Completion Token', value: s.completionTokens.toLocaleString() },
    { label: '总 Token', value: s.totalTokens.toLocaleString() },
  ]
})
</script>

<template>
  <div>
    <!-- Summary 卡片 -->
    <div class="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-6 gap-4 mb-6">
      <div
        v-for="item in summaryItems"
        :key="item.label"
        class="bg-white rounded-xl p-4 shadow-sm border border-[var(--color-border)]"
      >
        <p class="text-xs text-[var(--color-text-secondary)] mb-1">{{ item.label }}</p>
        <p class="text-xl font-semibold">{{ item.value }}</p>
      </div>
    </div>

    <!-- Provider 健康度 -->
    <div class="bg-white rounded-xl shadow-sm border border-[var(--color-border)] p-4">
      <h3 class="text-sm font-medium mb-3">Provider 健康度</h3>
      <div class="space-y-2">
        <div
          v-for="p in overview?.providers ?? []"
          :key="p.id"
          class="flex items-center gap-3 py-2 border-b border-[var(--color-border)] last:border-0"
        >
          <span
            class="w-2 h-2 rounded-full shrink-0"
            :style="{ backgroundColor: statusColor(p.enabled, p.configured) }"
          ></span>
          <span class="text-sm flex-1">{{ p.displayName }}</span>
          <span class="text-xs text-[var(--color-text-secondary)]">
            {{ p.enabled ? '已启用' : '已禁用' }}
            {{ p.configured ? '· 已配置' : '· 未配置' }}
          </span>
          <button
            class="text-xs px-2 py-1 rounded border border-[var(--color-border)] hover:bg-[var(--color-bg)]"
            :disabled="providerTests[p.id]?.testing"
            @click="testProvider(p.id)"
          >
            {{ providerTests[p.id]?.testing ? '测试中…' : '测试' }}
          </button>
          <span
            v-if="providerTests[p.id]?.message"
            class="text-xs"
            :class="providerTests[p.id]?.success ? 'text-[var(--color-green)]' : 'text-[var(--color-red)]'"
          >{{ providerTests[p.id]?.message }}</span>
        </div>
      </div>
    </div>
  </div>
</template>